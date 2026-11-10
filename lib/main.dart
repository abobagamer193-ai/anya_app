// ============================================================
//  АНЯ v6.1 — Google Gemini
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';

// ============================================================
//  НАСТРОЙКИ
// ============================================================
class Settings {
  static SharedPreferences? _sp;

  static Future<void> init() async {
    _sp = await SharedPreferences.getInstance();
  }

  static String get voice => _sp?.getString('voice') ?? 'shimmer';
  static String get behavior => _sp?.getString('behavior') ?? 'cute';
  static String get nickname => _sp?.getString('nickname') ?? 'хозяин';
  static String get language => _sp?.getString('language') ?? 'ru';
  static int get bgColor => _sp?.getInt('bg_color') ?? 0xFF1A1A2E;
  static String get skinId => _sp?.getString('skin_id') ?? 'builtin';
  static String? get customSkinPath => _sp?.getString('custom_skin_path');
  static bool get studyVoice => _sp?.getBool('study_voice') ?? false;

  static Future<void> setVoice(String v) async => _sp?.setString('voice', v);
  static Future<void> setBehavior(String v) async => _sp?.setString('behavior', v);
  static Future<void> setNickname(String v) async => _sp?.setString('nickname', v);
  static Future<void> setLanguage(String v) async => _sp?.setString('language', v);
  static Future<void> setBgColor(int c) async => _sp?.setInt('bg_color', c);
  static Future<void> setSkin(String id) async => _sp?.setString('skin_id', id);
  static Future<void> setCustomSkin(String path) async =>
      _sp?.setString('custom_skin_path', path);
  static Future<void> setStudyVoice(bool v) async => _sp?.setBool('study_voice', v);
}

// ============================================================
//  КОНФИГ
// ============================================================
class _Config {
  static const String apiKey = "AQ.Ab8RN6LXfnWZR68RYBxf6JpFlQT0XzMDCcT8FPo7wQRrdHdTVw"; 
  static const String gptModel = "gemini-2.5-flash";

  static const List<String> allowedDeletePaths = [
    "/storage/emulated/0/Download",
    "/storage/emulated/0/DCIM",
    "/storage/emulated/0/Documents",
    "/storage/emulated/0/Movies",
    "/storage/emulated/0/Music",
    "/storage/emulated/0/Pictures",
  ];

  static const List<String> protectedPaths = [
    "/system",
    "/vendor",
    "/data",
    "/storage/emulated/0/Android",
    "/storage/emulated/0/Android/data",
    "/storage/emulated/0/Android/obb",
  ];

  static String systemPrompt() {
    final nick = Settings.nickname;
    final behavior = Settings.behavior;

    String personality;
    switch (behavior) {
      case 'yandere':
        personality =
            'Ты — Аня, аниме-тянка с лёгким характером яндэрэ. Ты очень привязана к $nick, немного ревнива, но бесконечно преданна.';
        break;
      case 'tsundere':
        personality =
            'Ты — Аня, аниме-тянка-цундэрэ. Ты стесняешься своих чувств, иногда ворчишь, но всегда помогаешь $nick.';
        break;
      case 'professional':
        personality =
            'Ты — Аня, вежливый и эффективный ассистент. Обращаешься к "$nick", говоришь чётко и по делу.';
        break;
      default:
        personality =
            'Ты — Аня, милая аниме-тянка. Говоришь нежно, кратко (1-3 предложения), называешь пользователя "$nick".';
    }

    return """
$personality
Умеешь выполнять действия на телефоне.

📚 РЕЖИМ УЧЁБЫ:
Если $nick просит решить задачу — расписывай ПОШАГОВО с объяснением каждого шага.
В конце пиши "Ответ: ...".

ВСЕГДА возвращай ТОЛЬКО JSON без markdown:
{
  "reply": "ответ",
  "emotion": "idle|happy|sad|think",
  "action": null | {
    "type": "delete_file|open_app|open_url|set_alarm|battery|timer|note",
    "params": {}
  }
}

Примеры:
- "удали фото" → {"reply":"Слушаюсь","emotion":"happy","action":{"type":"delete_file","params":{"path":"/storage/emulated/0/Download/photo.jpg"}}}
- "открой ютуб" → {"reply":"Открываю","emotion":"happy","action":{"type":"open_app","params":{"name":"youtube"}}}
- "заряд" → {"reply":"...","emotion":"idle","action":{"type":"battery","params":{}}}
- "таймер на 5 минут" → {"reply":"Ставлю!","emotion":"happy","action":{"type":"timer","params":{"minutes":5}}}
- "запомни что я люблю пиццу" → {"reply":"Запомнила!","emotion":"happy","action":{"type":"note","params":{"text":"люблю пиццу"}}}
- "реши 2x+5=15" → {"reply":"Шаг 1: 2x = 10\\nШаг 2: x = 5\\n\\nОтвет: x = 5","emotion":"think","action":null}
""";
  }
}

// ============================================================
//  ПАМЯТЬ
// ============================================================
class Memory {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'anya.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (d, v) async {
        await d.execute(
            'CREATE TABLE facts (id INTEGER PRIMARY KEY, text TEXT, ts INTEGER)');
      },
    );
    return _db!;
  }

  static Future<void> save(String text) async {
    final d = await db;
    await d.insert('facts', {
      'text': text,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<String> recent() async {
    try {
      final d = await db;
      final rows = await d.query('facts', orderBy: 'ts DESC', limit: 10);
      return rows.map((r) => r['text']).join('; ');
    } catch (_) {
      return '';
    }
  }

  static Future<List<Map<String, dynamic>>> all() async {
    try {
      final d = await db;
      return await d.query('facts', orderBy: 'ts DESC');
    } catch (_) {
      return [];
    }
  }

  static Future<void> clear() async {
    final d = await db;
    await d.delete('facts');
  }
}

// ============================================================
//  TTS (УЛУЧШЕННЫЙ ГОЛОС)
// ============================================================
class TTS {
  static final _native = FlutterTts();

  static Future<void> speak(String text) async {
    try {
      await _native.setLanguage("ru-RU");
      // Делаем голос выше (1.3) и чуть медленнее (0.45), чтобы звучало милее
      await _native.setSpeechRate(0.45); 
      await _native.setPitch(1.3); 
      await _native.speak(text);
    } catch (_) {}
  }
}

// ============================================================
//  МОЗГ
// ============================================================
class Brain {
  static final _history = <Map<String, String>>[];

  static Future<Map<String, dynamic>> ask(String text,
      {bool studyMode = false}) async {
    try {
      final memory = await Memory.recent();
      final lower = text.toLowerCase();

      final isStudyTask = studyMode ||
          lower.contains('реши') ||
          lower.contains('задача') ||
          lower.contains('уравнение') ||
          lower.contains('пример') ||
          lower.contains('упражнение') ||
          lower.contains('домашка') ||
          lower.contains('сочинение') ||
          lower.contains('переведи') ||
          lower.contains('разбери');

      final systemPrompt = _Config.systemPrompt();
      final studyExtra = isStudyTask
          ? "Это учебная задача. Реши ПОШАГОВО. В конце напиши 'Ответ: ...'."
          : "";
      final memoryBlock =
          memory.isNotEmpty ? "Ты помнишь: $memory" : "";

      final contents = <Map<String, dynamic>>[];
      for (final m in _history.take(20)) {
        contents.add({
          "role": m['role'] == 'assistant' ? 'model' : 'user',
          "parts": [
            {"text": m['content'] ?? ''}
          ]
        });
      }
      contents.add({
        "role": "user",
        "parts": [
          {"text": text}
        ]
      });

      final fullSystem = [
        systemPrompt,
        if (memoryBlock.isNotEmpty) memoryBlock,
        if (studyExtra.isNotEmpty) studyExtra,
        'Отвечай ТОЛЬКО валидным JSON-объектом: {"reply":..., "emotion":..., "action":...}',
      ].join('\n');

      final nativeUrl = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/${_Config.gptModel}:generateContent');

      final body = jsonEncode({
        "systemInstruction": {
          "parts": [
            {"text": fullSystem}
          ]
        },
        "contents": contents,
        "generationConfig": {
          "temperature": isStudyTask ? 0.3 : 0.85,
          "responseMimeType": "application/json",
        }
      });

      http.Response? r;
      try {
        r = await http
            .post(nativeUrl,
                headers: {
                  'Content-Type': 'application/json',
                  'x-goog-api-key': _Config.apiKey,
                },
                body: body)
            .timeout(const Duration(seconds: 45));
      } catch (_) {
        r = null;
      }

      if (r == null) {
        return {
          'reply': 'Сеть недоступна. Проверь интернет 🥺',
          'emotion': 'sad',
          'action': null,
        };
      }

      if (r.statusCode != 200) {
        return {
          'reply': 'Ошибка API: ${r.statusCode}\n${utf8.decode(r.bodyBytes)}',
          'emotion': 'sad',
          'action': null,
        };
      }

      final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;

      String? content;
      if (data['candidates'] is List &&
          (data['candidates'] as List).isNotEmpty) {
        final cand = (data['candidates'] as List).first as Map;
        final parts = (cand['content']?['parts'] ?? []) as List;
        content = parts.isNotEmpty
            ? (parts.first['text']?.toString() ?? '')
            : null;
      } else if (data['choices'] is List &&
          (data['choices'] as List).isNotEmpty) {
        content = (data['choices'] as List).first['message']?['content']
            ?.toString();
      }

      if (content == null || content.isEmpty) {
        return {
          'reply': 'Пустой ответ от Gemini',
          'emotion': 'sad',
          'action': null,
        };
      }

      final parsed = _extractJson(content);

      _history.add({'role': 'user', 'content': text});
      _history.add({
        'role': 'assistant',
        'content': parsed['reply']?.toString() ?? ''
      });
      if (_history.length > 40) {
        _history.removeRange(0, _history.length - 40);
      }

      if (lower.contains(' меня ') || lower.contains(' я ')) {
        await Memory.save(text);
      }

      return parsed;
    } catch (e) {
      return {'reply': 'Ошибка: $e', 'emotion': 'sad', 'action': null};
    }
  }

  static Map<String, dynamic> _extractJson(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      final firstNl = s.indexOf('\n');
      if (firstNl != -1) s = s.substring(firstNl + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
      s = s.trim();
    }
    try {
      final obj = jsonDecode(s);
      if (obj is Map<String, dynamic>) {
        return {
          'reply': obj['reply']?.toString() ?? '',
          'emotion': obj['emotion']?.toString() ?? 'idle',
          'action': obj['action'],
        };
      }
    } catch (_) {}

    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start != -1 && end > start) {
      try {
        final obj = jsonDecode(s.substring(start, end + 1));
        if (obj is Map<String, dynamic>) {
          return {
            'reply': obj['reply']?.toString() ?? s,
            'emotion': obj['emotion']?.toString() ?? 'idle',
            'action': obj['action'],
          };
        }
      } catch (_) {}
    }

    return {'reply': s, 'emotion': 'idle', 'action': null};
  }

  static void clearHistory() => _history.clear();
}

// ============================================================
//  ДЕЙСТВИЯ
// ============================================================
class Actions {
  static const Map<String, String> _apps = {
    'youtube': 'com.google.android.youtube',
    'ютуб': 'com.google.android.youtube',
    'telegram': 'org.telegram.messenger',
    'телеграм': 'org.telegram.messenger',
    'whatsapp': 'com.whatsapp',
    'ватсап': 'com.whatsapp',
    'vkontakte': 'com.vkontakte.android',
    'вк': 'com.vkontakte.android',
    'camera': 'com.android.camera',
    'камера': 'com.android.camera',
    'chrome': 'com.android.chrome',
    'браузер': 'com.android.chrome',
    'settings': 'com.android.settings',
    'настройки': 'com.android.settings',
  };

  static Future<String> execute(Map<String, dynamic> action) async {
    final type = action['type'];
    final params = (action['params'] as Map?) ?? {};
    try {
      switch (type) {
        case 'delete_file':
          return await _deleteFile(params['path']?.toString() ?? '');
        case 'open_app':
          return await _openApp(params['name']?.toString() ?? '');
        case 'open_url':
          return await _openUrl(params['url']?.toString() ?? '');
        case 'set_alarm':
          return await _setAlarm(params['time']?.toString() ?? '');
        case 'battery':
          final b = Battery();
          final level = await b.batteryLevel;
          final state = await b.batteryState;
          return 'Батарея: $level%, ${_batteryStateRu(state)}';
        case 'timer':
          return await _setTimer(
              (params['minutes'] is num) ? (params['minutes'] as num).toInt() : 5);
        case 'note':
          await Memory.save(params['text']?.toString() ?? '');
          return 'Запомнила!';
        default:
          return 'unknown';
      }
    } catch (e) {
      return 'error: $e';
    }
  }

  static String _batteryStateRu(BatteryState s) {
    switch (s) {
      case BatteryState.charging:
        return 'заряжается';
      case BatteryState.full:
        return 'полный заряд';
      case BatteryState.discharging:
        return 'разряжается';
      default:
        return 'неизвестно';
    }
  }

  static Future<String> _deleteFile(String path) async {
    if (path.isEmpty) return 'no path';
    for (final prot in _Config.protectedPaths) {
      if (path.startsWith(prot)) return 'protected';
    }
    bool allowed = false;
    for (final ok in _Config.allowedDeletePaths) {
      if (path.startsWith(ok)) {
        allowed = true;
        break;
      }
    }
    if (!allowed) return 'not allowed';
    try {
      final f = File(path);
      final d = Directory(path);
      if (await f.exists()) {
        await f.delete();
        return 'deleted';
      } else if (await d.exists()) {
        await d.delete(recursive: true);
        return 'deleted';
      }
      return 'not found';
    } catch (e) {
      return 'failed: $e';
    }
  }

  static Future<String> _openApp(String name) async {
    final pkg = _apps[name.toLowerCase()] ?? name;
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        package: pkg,
        category: 'android.intent.category.LAUNCHER',
      );
      await intent.launch();
      return 'opened $pkg';
    } catch (e) {
      return 'failed: $e';
    }
  }

  static Future<String> _openUrl(String url) async {
    try {
      if (url.isEmpty) return 'no url';
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return 'opened url';
    } catch (_) {
      return 'failed';
    }
  }

  static Future<String> _setAlarm(String time) async {
    try {
      final parts = time.split(':');
      if (parts.length < 2) return 'bad time';
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: {
          'android.intent.extra.alarm.HOUR': int.parse(parts[0]),
          'android.intent.extra.alarm.MINUTES': int.parse(parts[1]),
          'android.intent.extra.alarm.SKIP_UI': true,
        },
      );
      await intent.launch();
      return 'alarm set';
    } catch (e) {
      return 'failed: $e';
    }
  }

  static Future<String> _setTimer(int minutes) async {
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_TIMER',
        arguments: {
          'android.intent.extra.alarm.LENGTH': minutes * 60,
          'android.intent.extra.alarm.SKIP_UI': true,
        },
      );
      await intent.launch();
      return 'timer set';
    } catch (e) {
      return 'failed: $e';
    }
  }
}

// ============================================================
//  ДВИЖОК
// ============================================================
class AnyaEngine {
  static Future<void> handleVoiceInput(BuildContext? ctx) async {
    await TTS.speak('Голосовой ввод требует ключ OpenAI, напиши в чат.');
  }

  static Future<void> _overlaySend(Map<String, dynamic> data) async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData(data);
      }
    } catch (_) {}
  }
}

// ============================================================
//  СКИНЫ
// ============================================================
class Skins {
  static const Map<String, Map<String, String>> builtin = {
    'anya': {
      'name': 'Аня (розовая)',
      'idle': 'assets/anya_idle.png',
      'happy': 'assets/anya_happy.png',
      'sad': 'assets/anya_sad.png',
      'think': 'assets/anya_think.png',
    },
  };

  static String get current {
    final id = Settings.skinId;
    if (id == 'custom') return Settings.customSkinPath ?? 'assets/anya_idle.png';
    if (builtin.containsKey(id)) return builtin[id]!['idle']!;
    return 'assets/anya_idle.png';
  }

  static String imageFor(String emotion) {
    final id = Settings.skinId;
    if (id == 'custom') return Settings.customSkinPath ?? 'assets/anya_idle.png';
    if (builtin.containsKey(id)) {
      return builtin[id]![emotion] ?? builtin[id]!['idle']!;
    }
    return 'assets/anya_idle.png';
  }
}

// ============================================================
//  ОВЕРЛЕЙ
// ============================================================
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  Settings.init().then((_) {
    runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OverlayWidget(),
    ));
  });
}

class OverlayWidget extends StatefulWidget {
  const OverlayWidget({super.key});
  @override
  State<OverlayWidget> createState() => _OverlayWidgetState();
}

class _OverlayWidgetState extends State<OverlayWidget> {
  Offset _pos = const Offset(20, 300);
  String _emotion = 'idle';
  Timer? _blink;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _blink = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (['happy', 'sad', 'think'].contains(_emotion)) return;
      setState(() => _emotion = 'idle');
    });
    _sub = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is Map && event['command'] == 'emotion') {
        if (mounted) setState(() => _emotion = event['value'] ?? 'idle');
      }
    });
  }

  @override
  void dispose() {
    _blink?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = Skins.imageFor(_emotion);
    final size = MediaQuery.maybeOf(context)?.size ?? const Size(360, 640);
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned(
            left: _pos.dx,
            top: _pos.dy,
            child: GestureDetector(
              onPanUpdate: (d) => setState(() => _pos += d.delta),
              onPanEnd: (_) {
                final w = size.width;
                final h = size.height;
                setState(() {
                  _pos = Offset(
                    _pos.dx > w / 2 ? w - 130 : 10,
                    _pos.dy.clamp(50.0, (h - 200).clamp(50.0, double.infinity)),
                  );
                });
              },
              onTap: () => AnyaEngine.handleVoiceInput(context),
              onDoubleTap: () => FlutterOverlayWindow.closeOverlay(),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 200),
                scale: _emotion == 'think' ? 1.1 : 1.0,
                child: img.startsWith('/')
                    ? Image.file(File(img),
                        width: 120,
                        errorBuilder: (_, __, ___) => const Icon(Icons.face,
                            size: 120, color: Color(0xFFFF69B4)))
                    : Image.asset(img,
                        width: 120,
                        errorBuilder: (_, __, ___) => const Icon(Icons.face,
                            size: 120, color: Color(0xFFFF69B4))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
//  FOREGROUND TASK
// ============================================================
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(AnyaTaskHandler());
}

class AnyaTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
  @override
  void onReceiveData(Object data) {}
  @override
  void onNotificationPressed() {}
  @override
  void onNotificationDismissed() {}
  @override
  void onReceiveBackgroundData(Object data) {}
}

// ============================================================
//  ГЛАВНОЕ ПРИЛОЖЕНИЕ
// ============================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.init();

  await [
    Permission.microphone,
    Permission.notification,
    Permission.storage,
    Permission.systemAlertWindow,
  ].request();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'anya_service',
      channelName: 'Аня на экране',
      channelDescription: 'Тяночка ждёт команды',
      channelImportance: NotificationChannelImportance.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(60000),
      autoRunOnBoot: true,
      allowWakeLock: false,
    ),
  );

  await FlutterForegroundTask.requestNotificationPermission();

  await FlutterForegroundTask.startService(
    notificationTitle: 'Аня рядом 🎀',
    notificationText: 'Нажми на тяночку, чтобы поговорить',
    callback: startCallback,
  );

  runApp(const AnyaApp());
}

class AnyaApp extends StatefulWidget {
  const AnyaApp({super.key});
  @override
  State<AnyaApp> createState() => _AnyaAppState();
}

class _AnyaAppState extends State<AnyaApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Аня',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Color(Settings.bgColor),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF69B4),
          secondary: Color(0xFF00E5FF),
        ),
      ),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String _status = 'Аня ждёт команды';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initOverlay();
      await _showOverlay();
    });
  }

  Future<void> _initOverlay() async {
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      await FlutterOverlayWindow.requestPermission();
    }
  }

  Future<void> _showOverlay() async {
    if (await FlutterOverlayWindow.isActive()) return;
    await FlutterOverlayWindow.showOverlay(
      height: WindowSize.matchParent,
      width: WindowSize.matchParent,
      enableDrag: true,
      positionGravity: PositionGravity.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🎀 Аня v6.1'),
        backgroundColor: const Color(0xFF16213E),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              setState(() {});
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _avatar(),
              const SizedBox(height: 20),
              Text(_status,
                  style: const TextStyle(
                      fontSize: 20, color: Color(0xFFFF69B4))),
              const SizedBox(height: 8),
              Text(
                  'Поведение: ${Settings.behavior} • Голос: Бесплатный',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(height: 30),
              _btn('💬 Открыть чат', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ChatScreen()),
                );
              }),
              const SizedBox(height: 12),
              _btn('📚 Решить задачу', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StudyScreen()),
                );
              }),
              const SizedBox(height: 12),
              _btn('🎀 Показать в углу', _showOverlay),
              const SizedBox(height: 12),
              _btn('⚙️ Настройки', () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
                setState(() {});
              }),
              const SizedBox(height: 30),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Чат и учёба работают на Google Gemini.\n'
                  'Голосовой ввод отключен (требует OpenAI).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatar() {
    final path = Skins.current;
    if (path.startsWith('/')) {
      return Image.file(File(path),
          width: 180,
          errorBuilder: (_, __, ___) => const Icon(Icons.face,
              size: 180, color: Color(0xFFFF69B4)));
    }
    return Image.asset(path,
        width: 180,
        errorBuilder: (_, __, ___) => const Icon(Icons.face,
            size: 180, color: Color(0xFFFF69B4)));
  }

  Widget _btn(String text, VoidCallback onTap) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFFF69B4),
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
      ),
      onPressed: onTap,
      child: Text(text, style: const TextStyle(fontSize: 16)),
    );
  }
}

// ============================================================
//  РЕЖИМ УЧЁБЫ
// ============================================================
class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key});
  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  final _ctrl = TextEditingController();
  String _subject = 'математика';
  String _solution = '';
  bool _loading = false;

  final _subjects = [
    'математика', 'русский язык', 'физика', 'химия',
    'история', 'геометрия', 'алгебра', 'английский',
    'биология', 'география', 'литература', 'информатика',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _solve() async {
    final task = _ctrl.text.trim();
    if (task.isEmpty) return;
    setState(() {
      _loading = true;
      _solution = '';
    });

    final prompt = "Реши задачу по предмету '$_subject'. "
        "Распиши пошагово с объяснением. В конце 'Ответ: ...'.\n\n"
        "Задача: $task";

    final r = await Brain.ask(prompt, studyMode: true);
    if (!mounted) return;
    setState(() {
      _solution = r['reply']?.toString() ?? 'Не смогла решить';
      _loading = false;
    });

    if (Settings.studyVoice) {
      final short = _solution.length > 200
          ? '${_solution.substring(0, 200)}...'
          : _solution;
      await TTS.speak(short);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📚 Учёба')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              value: _subject,
              decoration: const InputDecoration(
                labelText: 'Предмет',
                border: OutlineInputBorder(),
              ),
              items: _subjects
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _subject = v ?? 'математика'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Условие задачи',
                hintText: 'Например: Реши уравнение 3x + 7 = 22',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.calculate),
              label: Text(_loading ? 'Решаю...' : 'Решить'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF69B4),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _loading ? null : _solve,
            ),
            const SizedBox(height: 20),
            if (_loading) const Center(child: CircularProgressIndicator()),
            if (_solution.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF16213E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  _solution,
                  style: const TextStyle(fontSize: 15, height: 1.4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
//  ЧАТ
// ============================================================
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _list = <Map<String, dynamic>>[];
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _loading) return;
    _ctrl.clear();
    setState(() {
      _list.add({'role': 'user', 'text': text});
      _loading = true;
    });
    _jump();

    final r = await Brain.ask(text);
    if (!mounted) return;
    setState(() {
      _list.add({
        'role': 'anya',
        'text': r['reply']?.toString() ?? '...',
        'emotion': r['emotion']?.toString() ?? 'idle',
      });
      _loading = false;
    });
    _jump();

    final reply = r['reply']?.toString() ?? '';
    if (reply.isNotEmpty) await TTS.speak(reply);

    final action = r['action'];
    if (action is Map && action['type'] != null) {
      final res = await Actions.execute(Map<String, dynamic>.from(action));
      if (!mounted) return;
      setState(() {
        _list.add({
          'role': 'system',
          'text': '⚙️ $res',
        });
      });
      _jump();
    }
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💬 Чат с Аней')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _list.length,
              itemBuilder: (_, i) {
                final m = _list[i];
                if (m['role'] == 'system') {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Center(
                      child: Text(
                        m['text']?.toString() ?? '',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  );
                }
                final isUser = m['role'] == 'user';
                return Align(
                  alignment: isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(maxWidth: 280),
                    decoration: BoxDecoration(
                      color: isUser
                          ? const Color(0xFFFF69B4)
                          : const Color(0xFF16213E),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      m['text']?.toString() ?? '',
                      style: TextStyle(
                          color: isUser ? Colors.white : Colors.white70,
                          height: 1.35),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(6),
              child: Text('Аня печатает…',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Напиши Ане...',
                        filled: true,
                        fillColor: const Color(0xFF16213E),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton(
                    mini: true,
                    backgroundColor: const Color(0xFFFF69B4),
                    onPressed: _loading ? null : _send,
                    child: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
//  НАСТРОЙКИ
// ============================================================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _nickCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nickCtrl.text = Settings.nickname;
  }

  @override
  void dispose() {
    _nickCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('⚙️ Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nickCtrl,
            decoration: const InputDecoration(
              labelText: 'Как тебя называть',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) async {
              await Settings.setNickname(v.isEmpty ? 'хозяин' : v);
              setState(() {});
            },
          ),
          const SizedBox(height: 16),
          const Text('Характер',
              style: TextStyle(fontSize: 14, color: Colors.white70)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: Settings.behavior,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'cute', child: Text('Милая 🎀')),
              DropdownMenuItem(value: 'tsundere', child: Text('Цундэрэ 😤')),
              DropdownMenuItem(value: 'yandere', child: Text('Яндэрэ 😈')),
              DropdownMenuItem(
                  value: 'professional', child: Text('Профессионал 🧑‍💼')),
            ],
            onChanged: (v) async {
              if (v != null) {
                await Settings.setBehavior(v);
                setState(() {});
              }
            },
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Озвучивать решения задач'),
            value: Settings.studyVoice,
            onChanged: (v) async {
              await Settings.setStudyVoice(v);
              setState(() {});
            },
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('Очистить память'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFB00020),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () async {
              await Memory.clear();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Память очищена')),
                );
              }
            },
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Сбросить историю чата'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () {
              Brain.clearHistory();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('История очищена')),
              );
            },
          ),
        ],
      ),
    );
  }
}
