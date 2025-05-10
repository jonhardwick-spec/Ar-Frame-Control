import 'package:flutter/material.dart';
import '../../services/storage_service.dart';

class ConsoleLogScreen extends StatefulWidget {
  final StorageService storageService;
  const ConsoleLogScreen({super.key, required this.storageService});

  @override
  State<ConsoleLogScreen> createState() => _ConsoleLogScreenState();
}

class _ConsoleLogScreenState extends State<ConsoleLogScreen> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: widget.storageService.getLogs(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        final logs = snapshot.data ?? [];
        return ListView.builder(
          itemCount: logs.length,
          itemBuilder: (context, index) => ListTile(
            title: Text(logs[index]),
          ),
        );
      },
    );
  }
}