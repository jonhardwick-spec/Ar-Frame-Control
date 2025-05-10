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
  BuildContext? _scaffoldContext;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (BuildContext context) {
        _scaffoldContext = context;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(widget.frameService.isConnected ? 'Connected' : 'Disconnected'),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: widget.frameService.isConnected ? _disconnect : _connect,
                child: Text(widget.frameService.isConnected ? 'Disconnect' : 'Connect'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _connect() async {
    try {
      _log.info('attempting to connect to frame glasses');
      await widget.frameService.connectToGlasses();
      setState(() {});
      _log.info('connected to frame glasses');
    } catch (e) {
      _log.severe('error connecting to frame glasses: $e');
      if (_scaffoldContext != null) {
        ScaffoldMessenger.of(_scaffoldContext!).showSnackBar(
          SnackBar(content: Text('Connection Failed: $e')),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    try {
      _log.info('attempting to disconnect from frame glasses');
      await widget.frameService.disconnect();
      _log.info('disconnected from frame glasses');
    } catch (e) {
      _log.severe('error disconnecting: $e');
      if (_scaffoldContext != null) {
        ScaffoldMessenger.of(_scaffoldContext!).showSnackBar(
          SnackBar(content: Text('Disconnection Failed: $e')),
        );
      }
    }
  }
}