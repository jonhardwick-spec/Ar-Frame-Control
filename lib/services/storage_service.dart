import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';
import '../models/LogEntry.dart';
import '../models/log_entry.dart';

class StorageService {
  Database? _db;
  final _logStore = stringMapStoreFactory.store('logs');
  final _scriptStore = stringMapStoreFactory.store('scripts');

  final logsNotifier = ValueNotifier<List<LogEntry>>([]);
  List<LogEntry> get logs => logsNotifier.value;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/ar_project.db';
    _db = await databaseFactoryIo.openDatabase(path);
    return _db!;
  }

  Future<void> saveLog(LogEntry entry) async {
    try {
      logsNotifier.value = [...logsNotifier.value, entry];
      final db = await _database;
      await _logStore.add(db, {
        'timestamp': entry.timestamp.toIso8601String(),
        'message': entry.message,
      });
    } catch (e) {
      // Replace with logging in production
      // ignore: avoid_print
      print('Error saving log: $e');
    }
  }

  Future<List<String>> getLogs() async {
    try {
      final db = await _database;
      final records = await _logStore.find(db);
      return records.map((r) => '${r['timestamp']}: ${r['message']}').toList();
    } catch (e) {
      // Replace with logging in production
      // ignore: avoid_print
      print('Error retrieving logs: $e');
      return [];
    }
  }

  Future<void> clearLogs() async {
    try {
      final db = await _database;
      await _logStore.delete(db);
      logsNotifier.value = [];
    } catch (e) {
      // Replace with logging in production
      // ignore: avoid_print
      print('Error clearing logs: $e');
      throw Exception('Failed to clear logs: $e');
    }
  }

  Future<void> saveScript(String filename, String content) async {
    try {
      final db = await _database;
      await _scriptStore.add(db, {
        'filename': filename,
        'content': content,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      // Replace with logging in production
      // ignore: avoid_print
      print('Error saving script: $e');
      throw Exception('Failed to save script: $e');
    }
  }

  Future<String> readScript(String filename) async {
    try {
      final db = await _database;
      final record = await _scriptStore.findFirst(
        db,
        finder: Finder(filter: Filter.equals('filename', filename)),
      );
      if (record == null) {
        throw Exception('Script not found: $filename');
      }
      return record['content'] as String;
    } catch (e) {
      // Replace with logging in production
      // ignore: avoid_print
      print('Error reading script: $e');
      throw Exception('Failed to read script: $e');
    }
  }

  Future<void> dispose() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}