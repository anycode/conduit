import 'dart:async';
import 'dart:io';

import 'package:conduit_core/conduit_core.dart';
import 'package:mysql1/mysql1.dart';

import 'mysql_schema_generator.dart';
import 'mysql_query.dart';

/// The database layer responsible for carrying out [Query]s against MySql databases.
///
/// To interact with a MySql database, a [ManagedContext] must have an instance of this class.
/// Instances of this class are configured to connect to a particular MySql database.
class MySqlPersistentStore extends PersistentStore with MySqlSchemaGenerator {
  /// Creates an instance of this type from connection info.
  MySqlPersistentStore(
    this.username,
    this.password,
    this.host,
    this.port,
    this.databaseName, {
    bool useSSL = false,
  }) : isSSLConnection = useSSL;

  /// Same constructor as default constructor.
  ///
  /// Kept for backwards compatability.
  MySqlPersistentStore.fromConnectionInfo(
    this.username,
    this.password,
    this.host,
    this.port,
    this.databaseName, {
    bool useSSL = false,
  }) : isSSLConnection = useSSL;

  MySqlPersistentStore._from(MySqlPersistentStore from)
      : isSSLConnection = from.isSSLConnection,
        username = from.username,
        password = from.password,
        host = from.host,
        port = from.port,
        databaseName = from.databaseName;

  /// The logger used by instances of this class.
  static Logger logger = Logger("conduit");

  /// The username of the database user for the database this instance connects to.
  final String? username;

  /// The password of the database user for the database this instance connects to.
  final String? password;

  /// The host of the database this instance connects to.
  final String? host;

  /// The port of the database this instance connects to.
  final int? port;

  /// The name of the database this instance connects to.
  final String? databaseName;

  /// Whether this connection is established over SSL.
  final bool isSSLConnection;

  /// Amount of time to wait before connection fails to open.
  ///
  /// Defaults to 30 seconds.
  final Duration connectTimeout = const Duration(seconds: 30);

  static final Finalizer<MySqlConnection> _finalizer =
      Finalizer((connection) => connection.close());

  MySqlConnection? _databaseConnection;
  Completer<MySqlConnection>? _pendingConnectionCompleter;

  /// Retrieves a connection to the database this instance connects to.
  ///
  /// If no connection exists, one will be created. A store will have no more than one connection at a time.
  ///
  /// When executing queries, prefer to use [executionContext] instead. Failure to do so might result
  /// in issues when executing queries during a transaction.
  Future<MySqlConnection> getDatabaseConnection() async {
    if (_databaseConnection == null) {
      if (_pendingConnectionCompleter == null) {
        _pendingConnectionCompleter = Completer<MySqlConnection>();

        _connect().timeout(connectTimeout).then((conn) {
          _databaseConnection = conn;
          _pendingConnectionCompleter!.complete(_databaseConnection);
          _pendingConnectionCompleter = null;
          _finalizer.attach(this, _databaseConnection!, detach: this);
        }).catchError((e) {
          _pendingConnectionCompleter!.completeError(
            QueryException.transport(
              "unable to connect to database",
              underlyingException: e,
            ),
          );
          _pendingConnectionCompleter = null;
        });
      }

      return _pendingConnectionCompleter!.future;
    }

    return _databaseConnection!;
  }

  @override
  Query<T> newQuery<T extends ManagedObject>(
    ManagedContext context,
    ManagedEntity entity, {
    T? values,
  }) {
    final query = MySqlQuery<T>.withEntity(context, entity);
    if (values != null) {
      query.values = values;
    }
    return query;
  }

  @override
  Future<dynamic> execute(
    String sql, {
    Map<String, dynamic>? substitutionValues,
    Duration? timeout,
  }) async {
    timeout ??= const Duration(seconds: 30);
    final now = DateTime.now().toUtc();
    final dbConnection = await getDatabaseConnection();
    try {
      final rows = await dbConnection.query(
        sql,
        substitutionValues?.entries.map((e) => e.value).toList(),
      );

      final mappedRows = rows.map((row) => row.toList()).toList();
      logger.finest(
        () =>
            "Query:execute (${DateTime.now().toUtc().difference(now).inMilliseconds}ms) $sql -> $mappedRows",
      );
      return mappedRows;
    } on MySqlException catch (_) {
      // final interpreted = _interpretException(e);
      // if (interpreted != null) {
      //   throw interpreted;
      // }

      rethrow;
    }
  }

  @override
  Future close() async {
    await _databaseConnection?.close();
    _finalizer.detach(this);
    _databaseConnection = null;
  }

  @override
  Future<T?> transaction<T>(
    ManagedContext transactionContext,
    Future<T?> Function(ManagedContext transaction) transactionBlock,
  ) async {
    final dbConnection = await getDatabaseConnection();

    T? output;
    Rollback? rollback;
    try {
      await dbConnection.transaction((dbTransactionContext) async {
        transactionContext.persistentStore = _TransactionProxy(
          this,
          dbTransactionContext,
        );

        try {
          output = await transactionBlock(transactionContext);
        } on Rollback catch (e) {
          /// user triggered a manual rollback.
          /// TODO: there is currently no reliable way for a user to detect
          /// that a manual rollback occured.
          /// The documented method of checking the return value from this method
          /// does not work.
          rollback = e;
          dbTransactionContext.rollback();
        }
      });
    } on MySqlException catch (_) {
      // final interpreted = _interpretException(e);
      // if (interpreted != null) {
      //   throw interpreted;
      // }

      rethrow;
    }

    if (rollback != null) {
      throw rollback!;
    }

    return output;
  }

  @override
  Future<int> get schemaVersion async {
    try {
      final values = await execute(
        "SELECT versionNumber, dateOfUpgrade FROM $versionTableName ORDER BY dateOfUpgrade ASC",
      ) as List<List<dynamic>>;
      if (values.isEmpty) {
        return 0;
      }

      final version = await values.last.first;
      return version as int;
    } on MySqlException catch (_) {
      // if (e.code == MySqlErrorCode.undefinedTable) {
      //   return 0;
      // }
      rethrow;
    }
  }

  @override
  Future<Schema?> upgrade(
    Schema? fromSchema,
    List<Migration> withMigrations, {
    bool temporary = false,
  }) async {
    final connection = await getDatabaseConnection();

    Schema? schema = fromSchema;

    await connection.transaction((ctx) async {
      final transactionStore = _TransactionProxy(this, ctx);
      await _createVersionTableIfNecessary(ctx, temporary);

      withMigrations.sort((m1, m2) => m1.version!.compareTo(m2.version!));

      for (final migration in withMigrations) {
        migration.database =
            SchemaBuilder(transactionStore, schema, isTemporary: temporary);
        migration.database.store = transactionStore;

        final existingVersionRows = await ctx.query(
          "SELECT versionNumber, dateOfUpgrade FROM $versionTableName WHERE versionNumber >= ?",
          [migration.version],
        );
        if (existingVersionRows.isNotEmpty) {
          final date = existingVersionRows.first.last;
          throw MigrationException(
            "Trying to upgrade database to version ${migration.version}, but that migration has already been performed on $date.",
          );
        }

        logger.info("Applying migration version ${migration.version}...");
        await migration.upgrade();

        for (final cmd in migration.database.commands) {
          logger.info("\t$cmd");
          await ctx.query(cmd);
        }

        logger.info(
          "Seeding data from migration version ${migration.version}...",
        );
        await migration.seed();

        await ctx.query(
          "INSERT INTO $versionTableName (versionNumber, dateOfUpgrade) VALUES (${migration.version}, '${DateTime.now().toUtc().toIso8601String()}')",
        );

        logger
            .info("Applied schema version ${migration.version} successfully.");

        schema = migration.currentSchema;
      }
    });

    return schema;
  }

  @override
  Future<dynamic> executeQuery(
    String formatString,
    Map<String?, dynamic>? values,
    int timeoutInSeconds, {
    PersistentStoreQueryReturnType? returnType =
        PersistentStoreQueryReturnType.rows,
  }) async {
    final now = DateTime.now().toUtc();
    try {
      final dbConnection = await getDatabaseConnection();
      dynamic results;

      results = await dbConnection.query(
          formatString, values?.entries.map((e) => e.value).toList());

      logger.fine(
        () =>
            "Query (${DateTime.now().toUtc().difference(now).inMilliseconds}ms) $formatString Substitutes: ${values ?? "{}"} -> $results",
      );

      return results;
    } on TimeoutException catch (e) {
      throw QueryException.transport(
        "timed out connection to database",
        underlyingException: e,
      );
    } on MySqlException catch (e) {
      logger.fine(
        () =>
            "Query (${DateTime.now().toUtc().difference(now).inMilliseconds}ms) $formatString $values",
      );
      logger.warning(e.toString);
      // final interpreted = _interpretException(e);
      // if (interpreted != null) {
      //   throw interpreted;
      // }

      rethrow;
    }
  }

  // QueryException<MySqlException>? _interpretException(
  //   MySqlException exception,
  // ) {
  //   switch (exception.code) {
  //     case MySqlErrorCode.uniqueViolation:
  //       return QueryException.conflict(
  //         "entity_already_exists",
  //         ["${exception.tableName}.${exception.columnName}"],
  //         underlyingException: exception,
  //       );
  //     case MySqlErrorCode.notNullViolation:
  //       return QueryException.input(
  //         "non_null_violation",
  //         ["${exception.tableName}.${exception.columnName}"],
  //         underlyingException: exception,
  //       );
  //     case MySqlErrorCode.foreignKeyViolation:
  //       return QueryException.input(
  //         "foreign_key_violation",
  //         ["${exception.tableName}.${exception.columnName}"],
  //         underlyingException: exception,
  //       );
  //   }

  //   return null;
  // }

  Future _createVersionTableIfNecessary(
    TransactionContext context,
    bool temporary,
  ) async {
    final table = versionTable;
    final commands = createTable(table, isTemporary: temporary);
    final exists = await context.query(
      "SELECT to_regclass(@tableName:text)",
      [
        {"tableName": table.name}
      ],
    );

    if (exists.first.first != null) {
      return;
    }

    logger.info("Initializating database...");
    for (final cmd in commands) {
      logger.info("\t$cmd");
      await context.query(cmd);
    }
  }

  Future<MySqlConnection> _connect() async {
    logger.info("MySql connecting, $username@$host:$port/$databaseName.");
    final settings = ConnectionSettings(
      host: host!,
      port: port!,
      db: databaseName,
      user: username,
      password: password,
      useSSL: isSSLConnection,
    );

    return MySqlConnection.connect(settings, isUnixSocket: !Platform.isWindows);
  }
}

// TODO: Either PR for mysql1 package or create error code table here
// class MySqlErrorCode {
//   static const String duplicateTable = "42P07";
//   static const String undefinedTable = "42P01";
//   static const String undefinedColumn = "42703";
//   static const String uniqueViolation = "23505";
//   static const String notNullViolation = "23502";
//   static const String foreignKeyViolation = "23503";
// }

class _TransactionProxy extends MySqlPersistentStore {
  _TransactionProxy(this.parent, this.context) : super._from(parent);

  final MySqlPersistentStore parent;
  final TransactionContext context;
}