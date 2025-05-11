import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ar_project/services/frame_service.dart' as frame_service;
import 'package:ar_project/services/storage_service.dart';
import 'package:ar_project/models/log_entry.dart';

import '../../models/LogEntry.dart';

class ModuleControlScreen extends StatefulWidget {
  final frame_service.FrameService frameService;
  final StorageService storageService;

  const ModuleControlScreen({
    Key? key,
    required this.frameService,
    required this.storageService,
  }) : super(key: key);

  @override
  _ModuleControlScreenState createState() => _ModuleControlScreenState();
}

class _ModuleControlScreenState extends State<ModuleControlScreen> {
  List<String> _luaScripts = [];
  String? _selectedScript;
  String _scriptContent = '';
  bool _isLoading = false;
  String? _errorMessage;
  List<int>? _photoData;
  late TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: _scriptContent);
    _textController.addListener(() {
      _scriptContent = _textController.text;
    });
    _checkConnectionAndLoadScripts();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _checkConnectionAndLoadScripts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      if (await widget.frameService.verifyConnection()) {
        _luaScripts = await widget.frameService.listLuaScripts();
      } else {
        setState(() {
          _errorMessage = 'Not connected to Frame glasses';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _connectToGlasses() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await widget.frameService.connectToGlasses();
      _luaScripts = await widget.frameService.listLuaScripts();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _capturePhoto() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _photoData = null;
    });
    try {
      _photoData = await widget.frameService.capturePhoto();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _downloadScript() async {
    if (_selectedScript == null) {
      setState(() {
        _errorMessage = 'No script selected';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      String? content = await widget.frameService.downloadLuaScript(_selectedScript!);
      if (content != null) {
        setState(() {
          _scriptContent = content;
          _textController.text = content;
        });
      } else {
        setState(() {
          _errorMessage = 'Script not found';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _uploadScript() async {
    if (_selectedScript == null) {
      setState(() {
        _errorMessage = 'No script selected';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await widget.frameService.uploadLuaScript(_selectedScript!, _scriptContent);
      _luaScripts = await widget.frameService.listLuaScripts();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Frame Control'),
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: widget.frameService.connectionState,
        builder: (context, isConnected, child) {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isConnected ? 'Connected to Frame glasses' : 'Disconnected',
                  style: TextStyle(
                    fontSize: 18,
                    color: isConnected ? Colors.green : Colors.red,
                  ),
                ),
                const SizedBox(height: 16),
                if (!isConnected)
                  ElevatedButton(
                    onPressed: _isLoading ? null : _connectToGlasses,
                    child: const Text('Connect to Glasses'),
                  ),
                const SizedBox(height: 16),
                if (isConnected) ...[
                  ElevatedButton(
                    onPressed: _isLoading ? null : _capturePhoto,
                    child: const Text('Capture Photo'),
                  ),
                  const SizedBox(height: 16),
                  if (_photoData != null)
                    Image.memory(
                      Uint8List.fromList(_photoData!),
                      height: 200,
                      fit: BoxFit.contain,
                    ),
                  const SizedBox(height: 16),
                  DropdownButton<String>(
                    hint: const Text('Select Lua Script'),
                    value: _selectedScript,
                    items: _luaScripts
                        .map((script) => DropdownMenuItem(
                      value: script,
                      child: Text(script),
                    ))
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedScript = value;
                        _scriptContent = '';
                        _textController.text = '';
                        _errorMessage = null;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      ElevatedButton(
                        onPressed: _isLoading ? null : _downloadScript,
                        child: const Text('Download Script'),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _uploadScript,
                        child: const Text('Upload Script'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Script Content:'),
                  Expanded(
                    child: TextField(
                      maxLines: null,
                      expands: true,
                      enabled: !_isLoading,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                      controller: _textController,
                    ),
                  ),
                ],
                if (_isLoading)
                  const Center(child: CircularProgressIndicator()),
                if (_errorMessage != null)
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                const SizedBox(height: 16),
                const Text('Logs:'),
                Expanded(
                  child: ValueListenableBuilder<List<LogEntry>>(
                    valueListenable: widget.storageService.logsNotifier,
                    builder: (context, logs, child) {
                      return ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) {
                          final log = logs[index];
                          return ListTile(
                            title: Text(log.message),
                            subtitle: Text(log.timestamp.toString()),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}