import 'package:sembast/sembast_io.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ar_project/models/log_entry.dart';

class StorageService {
  Database? _db;
  final _logStore = stringMapStoreFactory.store('logs');

  Future<Database> get database async {
    _db ??= await databaseFactoryIo.openDatabase(
      join((await getApplicationDocumentsDirectory()).path, 'ar_project.db'),
    );
    return _db!;
  }

  Future<void> saveLog(LogEntry log) async {
    final db = await database;
    await _logStore.add(db, {
      'timestamp': log.timestamp,
      'message': log.message,
    });
  }

  Future<List<LogEntry>> getLogs() async {
    final db = await database;
    final records = await _logStore.find(db);
    return records
        .map((record) => LogEntry(
      timestamp: record.value['timestamp'] as String,
      message: record.value['message'] as String,
    ))
        .toList();
  }

  Future<void> clearLogs() async {
    final db = await database;
    await _logStore.delete(db);
  }
}