import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ialert_flutter/ialert_flutter.dart' as ia;
import 'package:shared_preferences/shared_preferences.dart';

/// Test app for the iAlert Flutter SDK: enter an app's public key, register
/// the device, then watch the Gateway state and the messages that arrive.
void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iAlert SDK test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4C2DB8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TestScreen(),
    );
  }
}

class TestScreen extends StatefulWidget {
  const TestScreen({super.key});

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  static const _defaultApiUrl = 'https://api.ialert.ir/api/v1';
  static const _defaultGatewayUrl = 'wss://gw.ialert.ir/v1/connect';

  final _keyField = TextEditingController();
  final _apiField = TextEditingController(text: _defaultApiUrl);
  final _gatewayField = TextEditingController(text: _defaultGatewayUrl);
  final _userField = TextEditingController(text: 'test-user-1');

  ia.IAlert? _client;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  ia.ConnectionState _state = ia.ConnectionState.idle;
  String? _deviceId;
  bool _busy = false;
  final List<ia.IAlertMessage> _messages = [];
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _restoreSettings();
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _keyField.text = prefs.getString('example.key') ?? '';
      _apiField.text = prefs.getString('example.api') ?? _defaultApiUrl;
      _gatewayField.text =
          prefs.getString('example.gateway') ?? _defaultGatewayUrl;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('example.key', _keyField.text.trim());
    await prefs.setString('example.api', _apiField.text.trim());
    await prefs.setString('example.gateway', _gatewayField.text.trim());
  }

  void _addLog(String line) {
    final time = TimeOfDay.now().format(context);
    setState(() => _log.insert(0, '$time  $line'));
  }

  /// Builds a fresh client for the entered key and URLs.
  Future<ia.IAlert?> _ensureClient() async {
    if (_client != null) {
      return _client;
    }

    try {
      final client = ia.IAlert(
        publicKey: _keyField.text.trim(),
        apiUrl: _apiField.text.trim(),
        gatewayUrl: _gatewayField.text.trim(),
      );
      _subscriptions
        ..add(client.connectionState.listen((state) {
          setState(() => _state = state);
          _addLog('gateway: ${state.name}');
        }))
        ..add(client.messages.listen((message) {
          setState(() => _messages.insert(0, message));
          _addLog('message (${message.source.name}): ${message.title}');
        }));
      _client = client;
      _deviceId = await client.deviceId;
      await _saveSettings();
      return client;
    } on ia.IAlertException catch (error) {
      _addLog('error: ${error.code} — ${error.message}');
      return null;
    }
  }

  Future<void> _run(String label, Future<void> Function(ia.IAlert) action) async {
    final client = await _ensureClient();
    if (client == null) {
      return;
    }

    setState(() => _busy = true);
    try {
      await action(client);
    } on ia.IAlertException catch (error) {
      _addLog('$label failed: ${error.status} ${error.code} — ${error.message}');
    } catch (error) {
      _addLog('$label failed: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _register() => _run('register', (client) async {
        final device = await client.register(
          externalUserId: _userField.text.trim().isEmpty
              ? null
              : _userField.text.trim(),
          tags: {'source': 'example-app'},
          locale: 'fa-IR',
        );
        setState(() => _deviceId = device.id);
        _addLog(
            'registered ${device.platform} device ${device.id} (subscribed: ${device.subscribed})');
      });

  Future<void> _syncInbox() => _run('inbox', (client) async {
        final fresh = await client.syncInbox();
        _addLog('inbox synced: ${fresh.length} new');
      });

  Future<void> _setTag() => _run('tags', (client) async {
        final device = await client.setTags(
            {'last_test': DateTime.now().toIso8601String().substring(0, 19)});
        _addLog('tags now: ${device.tags}');
      });

  Future<void> _unsubscribe() => _run('unsubscribe', (client) async {
        final device = await client.unsubscribe();
        _addLog('unsubscribed (subscribed: ${device.subscribed})');
      });

  Future<void> _click(ia.IAlertMessage message) =>
      _run('ack', (client) async {
        await client.ack([message.id], ia.AckEvent.clicked);
        _addLog('clicked ack sent for ${message.id}');
      });

  /// Drops the client so a changed key or URL takes effect.
  Future<void> _reset() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _client?.dispose();
    setState(() {
      _client = null;
      _state = ia.ConnectionState.idle;
      _deviceId = null;
      _messages.clear();
    });
    _addLog('client reset');
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _client?.dispose();
    _keyField.dispose();
    _apiField.dispose();
    _gatewayField.dispose();
    _userField.dispose();
    super.dispose();
  }

  Color _stateColor(ColorScheme colors) => switch (_state) {
        ia.ConnectionState.ready => const Color(0xFF5CFFB0),
        ia.ConnectionState.connecting => Colors.amber,
        ia.ConnectionState.closed => colors.error,
        ia.ConnectionState.idle => colors.outline,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final registered = _client != null && _deviceId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('iAlert SDK test'),
        actions: [
          IconButton(
            tooltip: 'Reset client',
            onPressed: _busy ? null : _reset,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _keyField,
            enabled: _client == null,
            decoration: const InputDecoration(
              labelText: 'Public key (ia_pk_…)',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _userField,
            decoration: const InputDecoration(
              labelText: 'External user id (optional)',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          ExpansionTile(
            title: const Text('Server URLs'),
            tilePadding: EdgeInsets.zero,
            children: [
              TextField(
                controller: _apiField,
                enabled: _client == null,
                decoration: const InputDecoration(labelText: 'API URL'),
              ),
              TextField(
                controller: _gatewayField,
                enabled: _client == null,
                decoration: const InputDecoration(labelText: 'Gateway URL'),
              ),
            ],
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.circle, color: _stateColor(colors), size: 16),
              title: Text('Gateway: ${_state.name}'),
              subtitle: Text(
                'Platform: ${_client?.platform ?? '—'}\nDevice: ${_deviceId ?? 'not registered'}',
              ),
              isThreeLine: true,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _register,
                icon: const Icon(Icons.app_registration),
                label: const Text('Register'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || !registered ? null : _syncInbox,
                icon: const Icon(Icons.inbox),
                label: const Text('Sync inbox'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || !registered ? null : _setTag,
                icon: const Icon(Icons.sell),
                label: const Text('Set tag'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || !registered ? null : _unsubscribe,
                icon: const Icon(Icons.notifications_off),
                label: const Text('Unsubscribe'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Messages (tap = clicked)',
              style: Theme.of(context).textTheme.titleMedium),
          if (_messages.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No messages yet. Send one from the panel.'),
            ),
          for (final message in _messages)
            Card(
              child: ListTile(
                title: Text(message.title ?? '(no title)'),
                subtitle: Text(
                    '${message.body ?? ''}\n${message.source.name} · ${message.id}'),
                isThreeLine: true,
                onTap: () => _click(message),
              ),
            ),
          const SizedBox(height: 20),
          Text('Log', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final line in _log.take(50))
            Text(line,
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
        ],
      ),
    );
  }
}
