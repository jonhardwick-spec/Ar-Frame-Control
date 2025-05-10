import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:ar_project/services/frame_service.dart';

class ModuleControlScreen extends StatefulWidget {
  final FrameService frameService;

  const ModuleControlScreen({super.key, required this.frameService});

  @override
  State<ModuleControlScreen> createState() => _ModuleControlScreenState();
}

class _ModuleControlScreenState extends State<ModuleControlScreen> {
  final Logger _log = Logger('ModuleControlScreen');
  bool _isConnecting = false;
  bool _isDisconnecting = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(widget.frameService.isConnected ? 'Connected' : 'Disconnected'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: (_isConnecting || _isDisconnecting)
                  ? null
                  : widget.frameService.isConnected
                  ? _disconnect
                  : _connect,
              child: Text(
                _isConnecting
                    ? 'Connecting...'
                    : _isDisconnecting
                    ? 'Disconnecting...'
                    : widget.frameService.isConnected
                    ? 'Disconnect'
                    : 'Connect',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _connect() async {
    if (!mounted) return;
    setState(() => _isConnecting = true);
    try {
      _log.info('Attempting to connect to Frame glasses');
      await widget.frameService.connectToGlasses();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected to Frame glasses')),
        );
      }
      _log.info('Connected to Frame glasses');
    } catch (e) {
      _log.severe('Error connecting to Frame glasses: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection Failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  Future<void> _disconnect() async {
    if (!mounted) return;
    setState(() => _isDisconnecting = true);
    try {
      _log.info('Attempting to disconnect from Frame glasses');
      await widget.frameService.disconnect();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Disconnected from Frame glasses')),
        );
      }
      _log.info('Disconnected from Frame glasses');
    } catch (e) {
      _log.severe('Error disconnecting: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnection Failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDisconnecting = false);
      }
    }
  }
}