import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Small token endpoint (no accounts): GET ?room=&name= -> {"url":"wss://...","token":"..."}
const tokenUrl = 'https://helmetcomms.drshaw01.workers.dev/token';
const duckHold = Duration(seconds: 2);

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
      title: 'Helmet Comms',
      theme: ThemeData.dark(useMaterial3: true),
      home: const Home());
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _store = const FlutterSecureStorage(); // encrypted on-device
  final _name = TextEditingController();
  final _room = TextEditingController(text: _code());
  List<String> _friends = [];
  Room? _lk;
  Timer? _poll, _release;
  bool _ducked = false;
  Set<String> _talking = {};

  static String _code() {
    const c = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(8, (_) => c[r.nextInt(c.length)]).join();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _name.text = await _store.read(key: 'name') ?? '';
    final f = await _store.read(key: 'friends');
    if (f != null) setState(() => _friends = List<String>.from(jsonDecode(f)));
  }

  Future<void> _saveFriend(String n) async {
    if (n.isEmpty || _friends.contains(n)) return;
    setState(() => _friends.add(n));
    await _store.write(key: 'friends', value: jsonEncode(_friends));
  }

  void _invite([String? who]) => Share.share(
      'Join me${who == null ? '' : ', $who'}: helmetcomms room ${_room.text}');

  Future<void> _connect() async {
    try {
      await _connect2();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Connect failed: $e')));
      }
    }
  }

  Future<void> _connect2() async {
    await _store.write(key: 'name', value: _name.text);
    final r = await http.get(Uri.parse(
        '$tokenUrl?room=${_room.text}&name=${Uri.encodeComponent(_name.text)}'));
    final j = jsonDecode(r.body);
    final room = Room(
        roomOptions: const RoomOptions(
            defaultAudioPublishOptions: AudioPublishOptions(dtx: true),
            defaultAudioCaptureOptions: AudioCaptureOptions(
                noiseSuppression: true,
                echoCancellation: true,
                autoGainControl: true)));
    await room.connect(j['url'], j['token']);
    await room.localParticipant?.setMicrophoneEnabled(true);
    await WakelockPlus.enable();
    _poll = Timer.periodic(const Duration(milliseconds: 150), (_) => _tick());
    setState(() => _lk = room);
  }

  // Server-side voice detection (isSpeaking) for me and everyone else.
  void _tick() {
    final room = _lk;
    if (room == null) return;
    final talk = <String>{
      if (room.localParticipant?.isSpeaking ?? false)
        room.localParticipant!.name,
      for (final p in room.remoteParticipants.values)
        if (p.isSpeaking) p.name,
    };
    if (talk.isNotEmpty) {
      _release?.cancel();
      _release = null;
      _duck(true);
    } else if (_ducked && _release == null) {
      _release = Timer(duckHold, () {
        _duck(false);
        _release = null;
      });
    }
    if (talk.length != _talking.length || !talk.containsAll(_talking)) {
      setState(() => _talking = talk);
    }
  }

  Future<void> _duck(bool on) async {
    if (on == _ducked) return;
    _ducked = on;
    final s = await AudioSession.instance;
    await s.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.duckOthers,
      androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    ));
    await s.setActive(on); // releasing focus restores the music volume
  }

  Future<void> _leave() async {
    _poll?.cancel();
    _release?.cancel();
    await _duck(false);
    await _lk?.disconnect();
    await WakelockPlus.disable();
    setState(() {
      _lk = null;
      _talking = {};
    });
  }

  @override
  Widget build(BuildContext c) {
    final live = _lk != null;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            if (!live) ...[
              Tooltip(
                  message: 'Shown to others in the call. Stored only on this phone.',
                  child: TextField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Your name'))),
              const SizedBox(height: 12),
              Tooltip(
                  message: 'Share this room code. Friends enter it to join.',
                  child: TextField(
                      controller: _room,
                      decoration: const InputDecoration(labelText: 'Room'))),
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                for (final f in _friends)
                  ActionChip(label: Text(f), onPressed: () => _invite(f)),
              ]),
              TextButton.icon(
                  onPressed: () async {
                    final t = TextEditingController();
                    await showDialog(
                        context: c,
                        builder: (_) => AlertDialog(
                            title: const Text('Friend name'),
                            content: TextField(controller: t),
                            actions: [
                              TextButton(
                                  onPressed: () {
                                    _saveFriend(t.text.trim());
                                    Navigator.pop(c);
                                  },
                                  child: const Text('Save'))
                            ]));
                  },
                  icon: const Icon(Icons.person_add),
                  label: const Text('Add friend')),
            ],
            if (live)
              Expanded(
                  child: Center(
                      child: Text(
                          _talking.isEmpty ? 'Listening' : _talking.join(', '),
                          style: TextStyle(
                              fontSize: 36,
                              color: _talking.isEmpty
                                  ? Colors.grey
                                  : Colors.greenAccent)))),
            if (!live) const Spacer(),
            Row(children: [
              if (live)
                Expanded(
                    child: SizedBox(
                        height: 80,
                        child: OutlinedButton(
                            onPressed: _invite, child: const Text('Invite')))),
              if (live) const SizedBox(width: 12),
              Expanded(
                  child: SizedBox(
                      height: 80,
                      child: FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: live ? Colors.red : null),
                          onPressed: live ? _leave : _connect,
                          child: Text(live ? 'Leave' : 'Connect',
                              style: const TextStyle(fontSize: 24))))),
            ]),
          ]),
        ),
      ),
    );
  }
}
