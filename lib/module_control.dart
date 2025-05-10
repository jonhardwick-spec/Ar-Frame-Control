import 'package:flutter/material.dart';
import 'package:ar_project/services/frame_service.dart';
import 'package:logging/logging.dart';

class ModuleControlTab extends StatefulWidget {
  final FrameService frameService;

  const ModuleControlTab({super.key, required this.frameService});

  @override
  State<ModuleControlTab> createState() => _ModuleControlTabState();
}

class _ModuleControlTabState extends State<ModuleControlTab> {
  final Logger _log = Logger('ModuleControlTab');
  bool _isConnecting = false;
  bool _useFrameBle = false;

  Future<void> _connect() async {
    if (widget.frameService.isConnected) {
      _log.info('already connected to frame glasses');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Already connected to Frame glasses')),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
    });

    try {
      _log.info('attempting to connect to frame glasses using ${_useFrameBle ? "frame_ble" : "frame_sdk"}');
      if (_useFrameBle) {
        await widget.frameService.connectToGlassesWithFrameBle();
      } else {
        await widget.frameService.connectToGlasses();
      }
      setState(() {
        _isConnecting = false;
      });
      _log.info('connected to frame glasses');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected to Frame glasses')),
        );
      }
    } catch (e) {
      setState(() {
        _isConnecting = false;
      });
      _log.severe('error connecting to frame glasses: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection Failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _isConnecting
                ? 'Connecting...'
                : widget.frameService.isConnected
                ? 'Connected'
                : 'Disconnected',
          ),
          SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isConnecting ? null : _connect,
            child: Text('Connect (${_useFrameBle ? "FrameBle" : "FrameSDK"})'),
          ),
          SizedBox(height: 10),
          ElevatedButton(
            onPressed: _isConnecting
                ? null
                : () {
              setState(() {
                _useFrameBle = !_useFrameBle;
              });
            },
            child: Text('Switch to ${_useFrameBle ? "FrameSDK" : "FrameBle"}'),
          ),
        ],
      ),
    );
  }
}