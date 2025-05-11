import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:ar_project/services/frame_service.dart';
import 'package:ar_project/services/storage_service.dart';

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
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  List<String> _scripts = [];
  bool _isLoadingScripts = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Frame Control')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Connection Status and Button
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        widget.frameService.isConnected ? 'Connected' : 'Disconnected',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
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
              ),
              const SizedBox(height: 20),
              // List Scripts
              Card(
                child: ExpansionTile(
                  title: const Text('List Scripts'),
                  subtitle: _isLoadingScripts
                      ? const Text('Loading...')
                      : Text('${_scripts.length} scripts found'),
                  children: [
                    if (_scripts.isEmpty && !_isLoadingScripts)
                      const ListTile(title: Text('No scripts found')),
                    ..._scripts.map((script) => ListTile(
                      title: Text(script),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _removeScript(script),
                      ),
                    )),
                    ListTile(
                      title: const Text('Refresh Script List'),
                      trailing: const Icon(Icons.refresh),
                      onTap: _listScripts,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Manage Scripts
              Card(
                child: ExpansionTile(
                  title: const Text('Manage Scripts'),
                  children: [
                    ListTile(
                      title: const Text('Upload Script'),
                      leading: const Icon(Icons.upload),
                      onTap: _uploadScript,
                    ),
                    ListTile(
                      title: const Text('Download Script'),
                      leading: const Icon(Icons.download),
                      onTap: _downloadScript,
                    ),
                    ListTile(
                      title: const Text('Remove Script'),
                      leading: const Icon(Icons.delete),
                      onTap: _selectAndRemoveScript,
                    ),
                  ],
                ),
              ),
            ],
          ),
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
        setState(() {
          _scripts.clear();
        });
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

  Future<void> _listScripts() async {
    if (!widget.frameService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to Frame glasses')),
      );
      return;
    }

    setState(() => _isLoadingScripts = true);
    try {
      _log.info('Fetching Lua scripts from Frame glasses');
      final scripts = await widget.frameService.listLuaScripts();
      if (mounted) {
        setState(() {
          _scripts = scripts;
          _isLoadingScripts = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Scripts loaded successfully')),
        );
      }
      _log.info('Fetched scripts: $scripts');
    } catch (e) {
      _log.severe('Error fetching scripts: $e');
      if (mounted) {
        setState(() => _isLoadingScripts = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load scripts: $e')),
        );
      }
    }
  }

  Future<void> _uploadScript() async {
    if (!widget.frameService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to Frame glasses')),
      );
      return;
    }

    final scriptNameController = TextEditingController();
    final scriptContentController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Upload Lua Script'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: scriptNameController,
              decoration: const InputDecoration(labelText: 'Script Name (e.g., myscript.lua)'),
            ),
            TextField(
              controller: scriptContentController,
              decoration: const InputDecoration(labelText: 'Script Content'),
              maxLines: 5,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final scriptName = scriptNameController.text.trim();
              final scriptContent = scriptContentController.text.trim();
              if (scriptName.isEmpty || scriptContent.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Script name and content are required')),
                );
                return;
              }
              try {
                _log.info('Uploading script: $scriptName');
                await widget.frameService.uploadLuaScript(scriptName, scriptContent);
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Uploaded script: $scriptName')),
                  );
                  await _listScripts(); // Refresh script list
                }
                _log.info('Uploaded script: $scriptName');
              } catch (e) {
                _log.severe('Error uploading script: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to upload script: $e')),
                  );
                }
              }
            },
            child: const Text('Upload'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadScript() async {
    if (!widget.frameService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to Frame glasses')),
      );
      return;
    }

    if (_scripts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No scripts available to download')),
      );
      return;
    }

    String? selectedScript;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Script to Download'),
        content: DropdownButton<String>(
          value: selectedScript,
          hint: const Text('Select a script'),
          isExpanded: true,
          items: _scripts.map((script) => DropdownMenuItem(
            value: script,
            child: Text(script),
          )).toList(),
          onChanged: (value) {
            selectedScript = value;
            Navigator.pop(context);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selectedScript == null) return;

    try {
      _log.info('Downloading script: $selectedScript');
      final scriptContent = await (await widget.frameService.downloadLuaScript(selectedScript!)) ?? '';
      if (scriptContent.isEmpty) {
        throw Exception('Script content is empty or not found');
      }
      await widget.storageService.saveScript(selectedScript!, scriptContent);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded script: $selectedScript to local storage')),
        );
      }
      _log.info('Downloaded script: $selectedScript');
    } catch (e) {
      _log.severe('Error downloading script: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to download script: $e')),
        );
      }
    }
  }

  Future<void> _removeScript(String scriptName) async {
    if (!widget.frameService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to Frame glasses')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Remove'),
        content: Text('Are you sure you want to remove $scriptName?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      _log.info('Removing script: $scriptName');
      await widget.frameService.removeLuaScript(scriptName);
      if (mounted) {
        setState(() {
          _scripts.remove(scriptName);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed script: $scriptName')),
        );
      }
      _log.info('Removed script: $scriptName');
    } catch (e) {
      _log.severe('Error removing script: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove script: $e')),
        );
      }
    }
  }

  Future<void> _selectAndRemoveScript() async {
    if (!widget.frameService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to Frame glasses')),
      );
      return;
    }

    if (_scripts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No scripts available to remove')),
      );
      return;
    }

    String? selectedScript;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Script to Remove'),
        content: DropdownButton<String>(
          value: selectedScript,
          hint: const Text('Select a script'),
          isExpanded: true,
          items: _scripts.map((script) => DropdownMenuItem(
            value: script,
            child: Text(script),
          )).toList(),
          onChanged: (value) {
            selectedScript = value;
            Navigator.pop(context);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selectedScript != null) {
      await _removeScript(selectedScript!);
    }
  }
}