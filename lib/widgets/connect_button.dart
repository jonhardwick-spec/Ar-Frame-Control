import 'package:flutter/material.dart';
import 'package:ar_project/services/frame_service.dart';

class ConnectButton extends StatelessWidget {
  final VoidCallback onPressed;
  final FrameService frameService;

  const ConnectButton({super.key, required this.onPressed, required this.frameService});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: frameService.isConnected ? null : frameService.connectToGlasses,
      backgroundColor: frameService.isConnected ? Colors.grey : Colors.blue,
      child: frameService.isConnected
          ? const Icon(Icons.bluetooth_connected)
          : const Icon(Icons.bluetooth),

    );
  }
}