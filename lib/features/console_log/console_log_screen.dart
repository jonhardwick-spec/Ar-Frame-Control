import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:ar_project/models/log_entry.dart';
import 'package:ar_project/services/frame_service.dart';

class ConsoleLogScreen extends StatefulWidget {
  final FrameService frameService;

  const ConsoleLogScreen({super.key, required this.frameService});

  @override
  State<ConsoleLogScreen> createState() => _ConsoleLogScreenState();
}

class _ConsoleLogScreenState extends State<ConsoleLogScreen> {
  final Logger _log = Logger('ConsoleLogScreen');
  List<LogEntry> _logs = [];

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  Future<void> _fetchLogs() async {
    try {
      final logs = await widget.frameService.storageService!.getLogs();
      setState(() {
        _logs = logs;
      });
      _log.info('Fetched ${logs.length} logs');
    } catch (e) {
      _log.severe('Error fetching logs: $e');
    }
  }

  Future<void> _clearLogs() async {
    try {
      await widget.frameService.storageService!.clearLogs();
      setState(() {
        _logs = [];
      });
      _log.info('Logs cleared');
    } catch (e) {
      _log.severe('Error clearing logs: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Console Log'),
      ),
      body: _logs.isEmpty
          ? const Center(child: Text('No logs available'))
          : ListView.builder(
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          return ListTile(
            title: Text(log.message),
            subtitle: Text(log.timestamp),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _clearLogs,
        child: const Icon(Icons.delete),
      ),
    );
  }
}