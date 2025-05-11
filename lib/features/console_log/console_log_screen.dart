import 'package:flutter/material.dart';

import '../../services/storage_service.dart';
class ConsoleLogScreen extends StatefulWidget {
  final StorageService storageService;
  const ConsoleLogScreen({super.key, required this.storageService});

  @override
  State<ConsoleLogScreen> createState() => _ConsoleLogScreenState();
}

class _ConsoleLogScreenState extends State<ConsoleLogScreen> {
  Future<void> _clearLogs() async {
    try {
      await widget.storageService.clearLogs();
      setState(() {}); // Trigger rebuild to refresh logs
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to clear logs: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Console Logs'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: FutureBuilder<List<String>>(
          future: widget.storageService.getLogs(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            final logs = snapshot.data ?? [];
            if (logs.isEmpty) {
              return const Center(child: Text('No logs available'));
            }
            return ListView.builder(
              itemCount: logs.length,
              itemBuilder: (context, index) => ListTile(
                title: Text(logs[index]),
              ),
            );
          },
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.all(16.0),
        child: FloatingActionButton(
          onPressed: _clearLogs,
          tooltip: 'Clear Logs',
          child: const Icon(Icons.delete),
        ),
      ),
    );
  }
}