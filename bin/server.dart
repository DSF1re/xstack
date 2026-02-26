import 'dart:convert';
import 'package:crypt/crypt.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf/shelf_io.dart';

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
          return response.change(headers: {'content-type': 'application/json'});
        },
      )
      .addHandler(appApi.router.call);

  final server = await serve(handler, '0.0.0.0', 8080);
  print('Сервер запущен: http://${server.address.host}:${server.port}');
}

class AppApi {
  final Connection conn;
  AppApi(this.conn);

  Router get router {
    final router = Router();

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
              'error':
                  'Некорректные данные. Пароль должен быть минимум 6 символов.',
            }),
          );
        }

        if (!RegExp(
          r"^[a-zA-Z0-9.a-zA-Z0-9.!#$%&'*+-/=?^_`{|}~]+@[a-zA-Z0-9]+\.[a-zA-Z]+",
        ).hasMatch(email)) {
          return Response.badRequest(
            body: jsonEncode({'error': 'Неверный формат email'}),
          );
        }

        final checkEmail = await conn.execute(
          r'SELECT id FROM client WHERE email = $1',
          parameters: [email],
        );

        if (checkEmail.isNotEmpty) {
          return Response(
            409,
            body: jsonEncode({'error': 'Этот email уже зарегистрирован'}),
          );
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
          jsonEncode({
            'status': 'success',
            'message': 'Пользователь успешно создан',
          }),
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': 'Ошибка сервера: $e'}),
        );
      }
    });

    router.post('/auth/login', (Request request) async {
      final payload = await request.readAsString();
      if (payload.isEmpty) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Пустой запрос'}),
        );
      }

      final data = jsonDecode(payload);
      final email = data['email'];
      final password = data['password'];

      if (email == null || password == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Введите email и пароль'}),
        );
      }

      final result = await conn.execute(
        r'SELECT id, password, name FROM client WHERE email = $1',
        parameters: [email],
      );

      if (result.isEmpty) {
        return Response.forbidden(
          jsonEncode({'error': 'Пользователь с таким email не найден'}),
        );
      }

      final userRow = result.first;
      final storedHash = userRow[1] as String;

      if (Crypt(storedHash).match(password)) {
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
      final users = res
          .map(
            (r) => {'id': r[0], 'name': r[1], 'surname': r[2], 'email': r[3]},
          )
          .toList();
      return Response.ok(jsonEncode(users));
    });
    router.get('/users/<id>', (Request request, String id) async {
      try {
        final userId = int.tryParse(id);
        if (userId == null) {
          return Response.badRequest(
            body: jsonEncode({'error': 'Некорректный формат ID'}),
          );
        }

        final result = await conn.execute(
          r'SELECT id, name, surname, patronymic, email, date_of_birth FROM client WHERE id = $1',
          parameters: [userId],
        );

        if (result.isEmpty) {
          return Response.notFound(
            jsonEncode({'error': 'Пользователь не найден'}),
          );
        }

        final r = result.first;
        final user = {
          'id': r[0],
          'name': r[1],
          'surname': r[2],
          'patronymic': r[3],
          'email': r[4],
          'date_of_birth': r[5] is DateTime
              ? (r[5] as DateTime).toIso8601String()
              : r[5].toString(),
        };

        return Response.ok(jsonEncode(user));
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': 'Ошибка сервера: $e'}),
        );
      }
    });
    router.get('/services', (Request request) async {
      final res = await conn.execute(
        'SELECT id, name, price, category FROM service',
      );
      final services = res
          .map(
            (r) => {
              'id': r[0],
              'name': r[1],
              'price': r[2],
              'category': r[3].toString(),
            },
          )
          .toList();
      return Response.ok(jsonEncode(services));
    });

    router.get('/orders', (Request request) async {
      final res = await conn.execute('''
        SELECT 
          o.id, 
          s.name as service_name, 
          c.name as client_name, 
          o.status, 
          o.date 
        FROM "order" o
        JOIN service s ON o.service_id = s.id
        JOIN client c ON o.client_id = c.id
      ''');

      final orders = res
          .map(
            (r) => {
              'id': r[0],
              'service': r[1],
              'client': r[2],
              'status': r[3].toString(),
              'date': r[4].toString(),
            },
          )
          .toList();

      return Response.ok(jsonEncode(orders));
    });

    return router;
  }
}
