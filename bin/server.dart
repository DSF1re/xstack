import 'dart:convert';
import 'dart:io';

import 'package:crypt/crypt.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
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
        final surname = data['surname']?.toString().trim() ?? '';
        final patronymic = data['patronymic']?.toString().trim();
        final dobString = data['date_of_birth']?.toString();

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

        final insertResult = await conn.execute(
          r'''INSERT INTO client (name, surname, patronymic, email, password, date_of_birth) 
          VALUES ($1, $2, $3, $4, $5, $6) RETURNING id''',
          parameters: [
            name,
            surname,
            patronymic,
            email,
            hashedPassword,
            dobString != null ? DateTime.parse(dobString) : null,
          ],
        );

        final newId = insertResult.first[0];

        return Response.ok(
          jsonEncode({
            'id': newId,
            'name': name,
            'surname': surname,
            'patronymic': patronymic,
            'email': email,
            'password': '',
            'date_of_birth': dobString,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': 'Ошибка сервера: $e'}),
        );
      }
    });

    router.post('/auth/login', (Request request) async {
      try {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);
        final email = data['email'];
        final password = data['password'];

        final result = await conn.execute(
          r'SELECT id, name, surname, patronymic, email, password, date_of_birth FROM client WHERE email = $1',
          parameters: [email],
        );

        if (result.isEmpty) {
          return Response.forbidden(
            jsonEncode({'error': 'Пользователь не найден'}),
          );
        }

        final userRow = result.first;

        if (Crypt(userRow[5] as String).match(password)) {
          final userJson = {
            'id': userRow[0],
            'name': userRow[1],
            'surname': userRow[2],
            'patronymic': userRow[3],
            'email': userRow[4],
            'password': '',
            'date_of_birth': (userRow[6] as DateTime).toIso8601String(),
          };

          return Response.ok(
            jsonEncode(userJson),
            headers: {'Content-Type': 'application/json'},
          );
        }

        return Response.forbidden(jsonEncode({'error': 'Неверный пароль'}));
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
        );
      }
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

    router.get('/services', (Request request) async {
      final res = await conn.execute(
        'SELECT id, name, description, price, image_url, category, rating FROM service',
      );
      return Response.ok(
        jsonEncode(
          res
              .map(
                (r) => {
                  'id': r[0],
                  'name': r[1],
                  'description': r[2],
                  'price': r[3],
                  'image_url': r[4],
                  'category': r[5],
                  'rating': r[6],
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
