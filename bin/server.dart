import 'dart:convert';
import 'dart:io';
import 'package:crypt/crypt.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_swagger_ui/shelf_swagger_ui.dart';

void main() async {
  final conn = await Connection.open(
    Endpoint(
      host: 'localhost',
      database: 'xstack',
      username: 'postgres',
      password: '1234',
    ),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );

  final appApi = AppApi(conn);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(
        (innerHandler) => (request) async {
          final response = await innerHandler(request);
          final path = request.url.path;

          if (path.startsWith('docs') ||
              path.endsWith('.js') ||
              path.endsWith('.css') ||
              path.contains('openapi.json')) {
            return response.change(
              headers: {'Access-Control-Allow-Origin': '*'},
            );
          }

          return response.change(
            headers: {
              if (!response.headers.containsKey('content-type'))
                'content-type': 'application/json; charset=utf-8',
              'Access-Control-Allow-Origin': '*',
              'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
              'Access-Control-Allow-Headers': 'Origin, Content-Type',
            },
          );
        },
      )
      .addHandler(appApi.router.call);

  final server = await serve(handler, '0.0.0.0', 8080);
  print('Сервер запущен: http://localhost:${server.port}/docs/');
}

class AppApi {
  final Connection conn;
  AppApi(this.conn);

  Router get router {
    final router = Router();

    final rootPath = Directory(Platform.script.toFilePath()).parent.parent.path;
    final jsonContent = File(
      '$rootPath/assets/openapi.json',
    ).readAsStringSync();

    final swaggerHandler = SwaggerUI(jsonContent, title: 'XStack API Docs');
    router.mount('/docs', swaggerHandler.call);

    router.post('/auth/register', (Request request) async {
      try {
        final payload = await request.readAsString();
        if (payload.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'Тело запроса пустое'}),
          );
        }

        final data = jsonDecode(payload);
        final email = data['email']?.toString().trim() ?? '';
        final password = data['password']?.toString() ?? '';
        final name = data['name']?.toString().trim() ?? '';

        if (name.isEmpty || email.isEmpty || password.length < 6) {
          return Response.badRequest(
            body: jsonEncode({
              'error': 'Некорректные данные. Пароль >= 6 символов.',
            }),
          );
        }

        final checkEmail = await conn.execute(
          r'SELECT id FROM client WHERE email = $1',
          parameters: [email],
        );
        if (checkEmail.isNotEmpty) {
          return Response(409, body: jsonEncode({'error': 'Email уже занят'}));
        }

        final hashedPassword = Crypt.sha256(password).toString();
        await conn.execute(
          r'INSERT INTO client (name, surname, email, password, date_of_birth) VALUES ($1, $2, $3, $4, $5)',
          parameters: [
            name,
            data['surname'] ?? '',
            email,
            hashedPassword,
            data['date_of_birth'],
          ],
        );

        return Response.ok(
          jsonEncode({'status': 'success', 'message': 'Пользователь создан'}),
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': 'Ошибка сервера: $e'}),
        );
      }
    });

    router.post('/auth/login', (Request request) async {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);
      final email = data['email'];
      final password = data['password'];

      final result = await conn.execute(
        r'SELECT id, password, name FROM client WHERE email = $1',
        parameters: [email],
      );
      if (result.isEmpty) {
        return Response.forbidden(
          jsonEncode({'error': 'Пользователь не найден'}),
        );
      }

      final userRow = result.first;
      if (Crypt(userRow[1] as String).match(password)) {
        return Response.ok(
          jsonEncode({
            'status': 'success',
            'user': {'id': userRow[0], 'name': userRow[2]},
          }),
        );
      }
      return Response.forbidden(jsonEncode({'error': 'Неверный пароль'}));
    });

    router.get('/users', (Request request) async {
      final res = await conn.execute(
        'SELECT id, name, surname, email FROM client',
      );
      return Response.ok(
        jsonEncode(
          res
              .map(
                (r) => {
                  'id': r[0],
                  'name': r[1],
                  'surname': r[2],
                  'email': r[3],
                },
              )
              .toList(),
        ),
      );
    });

    router.get('/users/<id>', (Request request, String id) async {
      final userId = int.tryParse(id);
      if (userId == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Некорректный ID'}),
        );
      }

      final result = await conn.execute(
        r'SELECT id, name, surname, patronymic, email, date_of_birth FROM client WHERE id = $1',
        parameters: [userId],
      );
      if (result.isEmpty) {
        return Response.notFound(jsonEncode({'error': 'Не найден'}));
      }

      final r = result.first;
      return Response.ok(
        jsonEncode({
          'id': r[0],
          'name': r[1],
          'surname': r[2],
          'patronymic': r[3],
          'email': r[4],
          'date_of_birth': r[5] is DateTime
              ? (r[5] as DateTime).toIso8601String()
              : r[5].toString(),
        }),
      );
    });

    // --- Эндпоинты Услуг и Заказов ---

    router.get('/services', (Request request) async {
      final res = await conn.execute(
        'SELECT id, name, price, category FROM service',
      );
      return Response.ok(
        jsonEncode(
          res
              .map(
                (r) => {
                  'id': r[0],
                  'name': r[1],
                  'price': r[2],
                  'category': r[3].toString(),
                },
              )
              .toList(),
        ),
      );
    });

    router.get('/orders', (Request request) async {
      final res = await conn.execute('''
        SELECT o.id, s.name, c.name, o.status, o.date 
        FROM "order" o
        JOIN service s ON o.service_id = s.id
        JOIN client c ON o.client_id = c.id
      ''');
      return Response.ok(
        jsonEncode(
          res
              .map(
                (r) => {
                  'id': r[0],
                  'service': r[1],
                  'client': r[2],
                  'status': r[3].toString(),
                  'date': r[4].toString(),
                },
              )
              .toList(),
        ),
      );
    });

    return router;
  }
}
