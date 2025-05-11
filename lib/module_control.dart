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

  Future<void> _connect(BuildContext context) async {
    if (!mounted) return;
    try {
      _log.info('attempting to connect to frame glasses');
      await widget.frameService.connectToGlasses();
      if (!mounted) return;
      setState(() {});
      _log.info('connected to frame glasses');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected to Frame glasses')),
      );
    } catch (e) {
      _log.severe('error connecting to frame glasses: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection Failed: $e')),
      );
    }
  }

  Future<void> _disconnect(BuildContext context) async {
    if (!mounted) return;
    try {
      _log.info('attempting to disconnect from frame glasses');
      await widget.frameService.disconnect();
      if (!mounted) return;
      setState(() {});
      _log.info('disconnected from frame glasses');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected from Frame glasses')),
      );
    } catch (e) {
      _log.severe('error disconnecting: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Disconnection Failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(widget.frameService.connectionState.value ? 'Connected' : 'Disconnected'),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: widget.frameService.connectionState.value
                ? () => _disconnect(context)
                : () => _connect(context),
            child: Text(widget.frameService.connectionState.value ? 'Disconnect' : 'Connect'),
          ),
        ],
      ),
    );
  }
}