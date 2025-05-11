import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:ar_project/services/frame_service.dart';
import 'package:ar_project/services/storage_service.dart';

import '../../models/LogEntry.dart';

class ModuleControlScreen extends StatefulWidget {
  final FrameService frameService;
  final StorageService storageService;

  const ModuleControlScreen({
    super.key,
    required this.frameService,
    required this.storageService,
  });

  @override
  State<ModuleControlScreen> createState() => _ModuleControlScreenState();
}

class _ModuleControlScreenState extends State<ModuleControlScreen> {
  final Logger _log = Logger('ModuleControlScreen');
  int? _batteryLevel;
  List<String> _scripts = [];
  bool _isLoading = false;
  late ValueNotifier<bool> _connectionNotifier;

  @override
  void initState() {
    super.initState();
    _log.info('ModuleControlScreen initialized');
    widget.storageService.saveLog(LogEntry(DateTime.now(), 'ModuleControlScreen initialized'));
    _connectionNotifier = ValueNotifier<bool>(widget.frameService.isConnected);
    _checkBattery();
    if (widget.frameService.isConnected) {
      _listScripts();
    }
  }

  Future<void> _toggleConnection() async {
    setState(() => _isLoading = true);
    try {
      if (widget.frameService.isConnected) {
        await widget.frameService.disconnect();
        _connectionNotifier.value = false;
        setState(() {
          _scripts = [];
          _batteryLevel = null;
        });
      } else {
        await widget.frameService.connectToGlasses();
        _connectionNotifier.value = true;
        await _checkBattery();
        await _listScripts();
      }
    } catch (e) {
      _log.severe('Error toggling connection: $e');
      widget.storageService.saveLog(LogEntry(DateTime.now(), 'Error toggling connection: $e'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection error: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _checkBattery() async {
    try {
      final level = await widget.frameService.checkBattery();
      if (mounted) {
        setState(() => _batteryLevel = level);
      }
      _log.info('Battery level updated: $_batteryLevel%');
      widget.storageService.saveLog(LogEntry(DateTime.now(), 'Battery level updated: $_batteryLevel%'));
    } catch (e) {
      _log.severe('Error checking battery: $e');
      widget.storageService.saveLog(LogEntry(DateTime.now(), 'Error checking battery: $e'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Battery check error: $e')),
        );
      }
    }
  }

  Future<void> _capturePhoto() async {
    setState(() => _isLoading = true);
    try {
      final photoData = await widget.frameService.capturePhoto();
      _log.info('Photo captured, size: ${photoData.length} bytes');
      widget.storageService.saveLog(LogEntry(DateTime.now(), 'Photo captured, size: ${photoData.length} bytes'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo captured successfully')),
        );
      }
    } catch (e) {
      _log.severe('Error capturing photo: $e');
      widget.storageService.saveLog(LogEntry(DateTime.now(), 'Error capturing photo: $e'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo capture error: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _listScripts() async {
    setState(() => _isLoading = true);
    try {
      final scripts = await widget.frameService.listLuaScripts();
      if (mounted) {
        setState(() => _scripts = scripts);
      }
      _log.info('Scripts listed: $_scripts');
      widget.storageService.saveLog(LogEntry(DateTime.now(), 'Scripts listed: $_scripts'));
    } catch (e) {
      _log.severe('Error listing scripts: $e');
      widget.storageService.saveLog(LogEntry(DateTime.now(), 'Error listing scripts: $e'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Script listing error: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Frame Controller'),
        backgroundColor: Theme.of(context).primaryColor,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: _connectionNotifier,
              builder: (context, isConnected, _) {
                return Column(
                  children: [
                    Text(
                      'Status: ${isConnected ? 'Connected' : 'Disconnected'}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _toggleConnection,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(
                        _isLoading
                            ? 'Processing...'
                            : isConnected
                            ? 'Disconnect'
                            : 'Connect',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Text(
              'Battery: ${_batteryLevel != null ? '$_batteryLevel%' : 'Unknown'}',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading || !_connectionNotifier.value
                  ? null
                  : _capturePhoto,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text(
                'Capture Photo',
                style: TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading || !_connectionNotifier.value
                  ? null
                  : _listScripts,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text(
                'Refresh Lua Scripts',
                style: TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _scripts.isEmpty
                  ? const Center(
                child: Text(
                  'No scripts found',
                  style: TextStyle(fontSize: 16),
                ),
              )
                  : ListView.builder(
                itemCount: _scripts.length,
                itemBuilder: (context, index) {
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      title: Text(
                        _scripts[index],
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isLoading || !_connectionNotifier.value ? null : _checkBattery,
        backgroundColor: Theme.of(context).primaryColor,
        child: const Icon(Icons.battery_std),
      ),
    );
  }

  @override
  void dispose() {
    _connectionNotifier.dispose();
    _log.info('ModuleControlScreen disposed');
    widget.storageService.saveLog(LogEntry(DateTime.now(), 'ModuleControlScreen disposed'));
    super.dispose();
  }
}