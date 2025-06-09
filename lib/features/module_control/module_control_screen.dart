import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ar_project/services/frame_service.dart' as frame_service;
import 'package:ar_project/services/storage_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/LogEntry.dart';
import '../../models/log_entry.dart';

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
  bool _isLoading = false;
  String? _errorMessage;
  Uint8List? _photoData;
  String? _scriptDownloadPath;
  final ValueNotifier<String?> _selectedScriptNotifier = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _checkConnectionAndLoadScripts();
    _setDefaultDownloadPath();
  }

  @override
  void dispose() {
    _selectedScriptNotifier.dispose();
    super.dispose();
  }

  Future<void> _setDefaultDownloadPath() async {
    final directory = await getApplicationDocumentsDirectory();
    _scriptDownloadPath = directory.path;
  }

  Future<void> _requestPermissions() async {
    var statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.camera,
      Permission.storage,
      Permission.locationWhenInUse,
    ].request();
    statuses.forEach((permission, status) {
      if (status.isDenied) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$permission denied. Please grant to use all features.'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _requestPermissions,
            ),
          ),
        );
      }
    });
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
      final (imageData, _) = await widget.frameService.capturePhoto();
      setState(() {
        _photoData = imageData;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Photo captured: ${imageData.length} bytes')),
      );
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
      await widget.frameService.downloadLuaScript(_selectedScript!);
      final filePath = '$_scriptDownloadPath/$_selectedScript';
      final file = File(filePath);
      await file.writeAsString(_selectedScript!);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Script saved to $filePath')),
      );
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

  Future<void> _selectDownloadPath() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      setState(() {
        _scriptDownloadPath = selectedDirectory;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download path set to $_scriptDownloadPath')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Frame Control'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Theme.of(context).primaryColor,
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: ValueListenableBuilder<bool>(
          valueListenable: widget.frameService.connectionState,
          builder: (context, isConnected, child) {
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Battery Status
                  BatteryStatusWidget(frameService: widget.frameService),
                  const SizedBox(height: 12),
                  // Connection Status
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isConnected ? 'Connected' : 'Disconnected',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isConnected ? Colors.green : Colors.red,
                            ),
                          ),
                          if (!isConnected)
                            ElevatedButton(
                              onPressed: _isLoading ? null : _connectToGlasses,
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                textStyle: const TextStyle(fontSize: 14),
                              ),
                              child: const Text('Connect'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (isConnected) ...[
                    // Actions
                    Card(
                      elevation: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Actions',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: _isLoading ? null : _capturePhoto,
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      textStyle: const TextStyle(fontSize: 14),
                                    ),
                                    child: const Text('Capture Photo'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: _isLoading ? null : _selectDownloadPath,
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      textStyle: const TextStyle(fontSize: 14),
                                    ),
                                    child: const Text('Set Download Path'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Script Selection
                    Card(
                      elevation: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Lua Scripts',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            ValueListenableBuilder<String?>(
                              valueListenable: _selectedScriptNotifier,
                              builder: (context, selectedScript, child) {
                                return DropdownButton<String>(
                                  isExpanded: true,
                                  hint: const Text('Select Lua Script'),
                                  value: selectedScript,
                                  items: _luaScripts.map((script) {
                                    return DropdownMenuItem(
                                      value: script,
                                      child: Text(script, overflow: TextOverflow.ellipsis),
                                    );
                                  }).toList(),
                                  onChanged: (value) {
                                    _selectedScriptNotifier.value = value;
                                    _selectedScript = value;
                                    setState(() {
                                      _errorMessage = null;
                                    });
                                  },
                                );
                              },
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: _isLoading ? null : _downloadScript,
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                textStyle: const TextStyle(fontSize: 14),
                              ),
                              child: const Text('Download Script'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Photo Display
                    if (_photoData != null)
                      Card(
                        elevation: 2,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Captured Photo',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                height: 150,
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey),
                                ),
                                child: Image.memory(
                                  _photoData!,
                                  fit: BoxFit.contain,
                                  width: double.infinity,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  if (_isLoading)
                    const Padding(
                      padding: EdgeInsets.all(12.0),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red, fontSize: 14),
                      ),
                    ),
                  const SizedBox(height: 12),
                  // Logs
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Logs',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            height: 200,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: ValueListenableBuilder<List<LogEntry>>(
                              valueListenable: widget.storageService.logsNotifier,
                              builder: (context, logs, child) {
                                return ListView.builder(
                                  itemCount: logs.length,
                                  itemBuilder: (context, index) {
                                    final log = logs[index];
                                    return ListTile(
                                      title: Text(log.message, style: const TextStyle(fontSize: 12)),
                                      subtitle: Text(
                                        log.timestamp.toString(),
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class BatteryStatusWidget extends StatelessWidget {
  final frame_service.FrameService frameService;

  const BatteryStatusWidget({Key? key, required this.frameService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: StreamBuilder<int>(
          stream: frameService.getBatteryLevelStream(),
          initialData: 0,
          builder: (context, snapshot) {
            final batteryLevel = snapshot.data ?? 0; // Use 0 if null
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Battery',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Container(
                      width: 80,
                      height: 16,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: batteryLevel / 100,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                batteryLevel <= 20 ? Colors.red : Colors.yellow,
                                batteryLevel >= 80 ? Colors.green : Colors.yellow,
                              ],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$batteryLevel%',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}