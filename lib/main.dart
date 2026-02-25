// Outfit Studio - Single-file Flutter App
// Features:
// - Wardrobe (items with photo, category, color, warmth, occasion, season, laundry state)
// - Weather-aware outfit suggestions (Open-Meteo) + season filter
// - Favorites (save combos)
// - History with per-entry delete, detail view, like/dislike feedback
// - Learning: item & combo affinities updated from feedback and wear events
// - Statistics screen (usage + feedback insights)
//
// NOTE: This file intentionally stays dependency-light.
// Required pubspec dependencies (already used in your project):
//   flutter, image_picker, path, path_provider, geolocator, http

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = OutfitStore();
  await store.load();

  final weather = WeatherStore();
  weather.refresh(); // fire & forget

  final seenOnboarding = store.getFlag('seen_onboarding', defaultValue: false);
  runApp(OutfitApp(store: store, weather: weather, seenOnboarding: seenOnboarding));
}

/* -------------------------------------------------------------------------- */
/*                                    APP                                     */
/* -------------------------------------------------------------------------- */

class OutfitApp extends StatelessWidget {
  final OutfitStore store;
  final WeatherStore weather;
  final bool seenOnboarding;

  const OutfitApp({
    super.key,
    required this.store,
    required this.weather,
    required this.seenOnboarding,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Outfit Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF070A1C),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00E5FF), brightness: Brightness.dark),
      ),
      home: seenOnboarding ? HomeShell(store: store, weather: weather) : OnboardingPage(store: store, weather: weather),
    );
  }
}

/// A tiny wrapper that can show a one-time "what to do first" coach,
/// without touching the big HomePage widget.
class HomeShell extends StatefulWidget {
  final OutfitStore store;
  final WeatherStore weather;

  const HomeShell({super.key, required this.store, required this.weather});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  bool _coachShownThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowCoach());
  }

  Future<void> _maybeShowCoach() async {
    if (!mounted) return;
    if (_coachShownThisSession) return;

    final store = widget.store;
    final shouldShow = !store.getFlag('seen_coach_add', defaultValue: false) && store.items.isEmpty;
    if (!shouldShow) return;

    _coachShownThisSession = true;

    final res = await showDialog<_CoachAction>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Hızlı Başlangıç'),
content: const Text(
  '1) Kıyafet Ekle ile dolabını doldur\n'
  '2) Kombin Oluştur ile skorlu öneri al\n'
  '3) “Giydim” + Beğeni/Beğenmedim ver → uygulama seni öğrenir',
),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, _CoachAction.close),
              child: const Text('Kapat'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, _CoachAction.addItem),
              child: const Text('Kıyafet Ekle'),
            ),
          ],
        );
      },
    );

    await widget.store.setFlag('seen_coach_add', true);

    if (!mounted) return;
    if (res == _CoachAction.addItem) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => AddEditClothingPage(store: widget.store)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return HomePage(store: widget.store, weather: widget.weather);
  }
}

enum _CoachAction { close, addItem }

/// Onboarding (first run tutorial). No extra packages.
/// State is stored inside OutfitStore.settings in outfit_db.json.
class OnboardingPage extends StatefulWidget {
  final OutfitStore store;
  final WeatherStore weather;

  const OnboardingPage({super.key, required this.store, required this.weather});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pc = PageController();
  int _i = 0;

  late final List<_OnbPage> _pages = const [
    _OnbPage(
      icon: Icons.auto_awesome,
      title: 'Hoş geldin',
      body:
          'Bu uygulama dolabını düzenler, hava durumuna göre kombin önerir ve geri bildirimlerinle zamanla daha iyi öneri yapar.',
    ),
    _OnbPage(
      icon: Icons.add_photo_alternate_rounded,
      title: 'Kıyafet ekle',
      body: 'Fotoğraf seç → kategori, renk, kalınlık, sezon ve not gir. Temeli düzgün kur, öneriler uçsun.',
    ),
    _OnbPage(
      icon: Icons.checkroom_rounded,
      title: 'Kombin oluştur',
      body: 'Etkinliği seç (Günlük / Spor / Smart / Formal). Skorlu öneriler gelir. “Giydim” dediğinde sistem öğrenir.',
    ),
    _OnbPage(
      icon: Icons.insights_rounded,
      title: 'Geçmiş & İstatistik',
      body: 'Geçmişten kombin sil/favorile, beğen–beğenme ver. İstatistiklerde alışkanlıklarını gör.',
    ),
  ];

  Future<void> _finish() async {
    await widget.store.setFlag('seen_onboarding', true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeShell(store: widget.store, weather: widget.weather)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _i == _pages.length - 1;

    return Scaffold(
      backgroundColor: const Color(0xFF070A12),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pc,
                itemCount: _pages.length,
                onPageChanged: (v) => setState(() => _i = v),
                itemBuilder: (_, idx) => _pages[idx],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  TextButton(onPressed: _finish, child: const Text('Atla')),
                  const Spacer(),
                  Text('${_i + 1}/${_pages.length}', style: const TextStyle(color: Colors.white70)),
                  const Spacer(),
                  FilledButton(
                    onPressed: isLast
                        ? _finish
                        : () => _pc.nextPage(duration: const Duration(milliseconds: 220), curve: Curves.easeOut),
                    child: Text(isLast ? 'Başla' : 'Devam'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnbPage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _OnbPage({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            height: 110,
            width: 110,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.06),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withOpacity(.10)),
            ),
            child: Icon(icon, color: Colors.cyanAccent, size: 54),
          ),
          const SizedBox(height: 22),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.4)),
        ],
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                   MODELS                                   */
/* -------------------------------------------------------------------------- */

enum LaundryState { ready, dirty, laundry }

extension LaundryStateX on LaundryState {
  String get code => name;
  String get label {
    switch (this) {
      case LaundryState.ready:
        return 'Temiz';
      case LaundryState.dirty:
        return 'Kirli';
      case LaundryState.laundry:
        return 'Çamaşırda';
    }
  }

  IconData get icon {
    switch (this) {
      case LaundryState.ready:
        return Icons.check_circle_rounded;
      case LaundryState.dirty:
        return Icons.warning_rounded;
      case LaundryState.laundry:
        return Icons.local_laundry_service_rounded;
    }
  }

  static LaundryState fromCode(String? code) {
    switch (code) {
      case 'dirty':
        return LaundryState.dirty;
      case 'laundry':
        return LaundryState.laundry;
      case 'ready':
      default:
        return LaundryState.ready;
    }
  }
}

enum Season { winter, spring, summer, autumn }

extension SeasonX on Season {
  String get code => name;
  String get label {
    switch (this) {
      case Season.winter:
        return 'Kış';
      case Season.spring:
        return 'İlkbahar';
      case Season.summer:
        return 'Yaz';
      case Season.autumn:
        return 'Sonbahar';
    }
  }

  static Season fromCode(String? code) {
    switch (code) {
      case 'winter':
        return Season.winter;
      case 'spring':
        return Season.spring;
      case 'summer':
        return Season.summer;
      case 'autumn':
        return Season.autumn;
      default:
        return current();
    }
  }

  static Season current([DateTime? now]) {
    final m = (now ?? DateTime.now()).month;
    if (m == 12 || m == 1 || m == 2) return Season.winter;
    if (m >= 3 && m <= 5) return Season.spring;
    if (m >= 6 && m <= 8) return Season.summer;
    return Season.autumn;
  }
}

class ClothingItem {
  final String id;

  /// Stored under app documents: .../outfit_images/<id>.<ext>
  final String imagePath;
  final String? imageName;

  final String category; // TOP/BOTTOM/OUTER/SHOES/ACCESSORY
  final String color; // Black/White/Red...
  final String note;

  final LaundryState laundry;
  final DateTime createdAt;
  final DateTime? lastWornAt;

  /// 1=İnce 2=Orta 3=Kalın (multi-select)
  final List<int> warmths;

  /// casual/sport/smart/formal (multi-select)
  final List<String> occasions;

  /// winter/spring/summer/autumn (multi-select)
  final List<String> seasons;

  const ClothingItem({
    required this.id,
    required this.imagePath,
    this.imageName,
    required this.category,
    required this.color,
    required this.note,
    this.laundry = LaundryState.ready,
    required this.createdAt,
    this.lastWornAt,
    required this.warmths,
    required this.occasions,
    required this.seasons,
  });

  ClothingItem copyWith({
    String? imagePath,
    String? imageName,
    String? category,
    String? color,
    String? note,
    LaundryState? laundry,
    DateTime? lastWornAt,
    bool clearLastWornAt = false,
    List<int>? warmths,
    List<String>? occasions,
    List<String>? seasons,
  }) {
    return ClothingItem(
      id: id,
      imagePath: imagePath ?? this.imagePath,
      imageName: imageName ?? this.imageName,
      category: category ?? this.category,
      color: color ?? this.color,
      note: note ?? this.note,
      laundry: laundry ?? this.laundry,
      createdAt: createdAt,
      lastWornAt: clearLastWornAt ? null : (lastWornAt ?? this.lastWornAt),
      warmths: warmths ?? this.warmths,
      occasions: occasions ?? this.occasions,
      seasons: seasons ?? this.seasons,
    );
  }

  bool supportsWarmth(int w) => warmths.contains(w);
  bool supportsOccasion(String o) => occasions.contains(o);
  bool supportsSeason(Season s) => seasons.contains(s.code);

  Map<String, dynamic> toJson() => {
        'id': id,
        'imagePath': imagePath,
        'imageName': imageName,
        'category': category,
        'color': color,
        'note': note,
        'laundry': laundry.code,
        'createdAt': createdAt.toIso8601String(),
        'lastWornAt': lastWornAt?.toIso8601String(),
        'warmths': warmths,
        'occasions': occasions,
        'seasons': seasons,
      };

  factory ClothingItem.fromJson(Map<String, dynamic> j) {
    return ClothingItem(
      id: (j['id'] as String?) ?? _uid(),
      imagePath: (j['imagePath'] as String?) ?? '',
      imageName: j['imageName'] as String?,
      category: (j['category'] as String?) ?? 'TOP',
      color: (j['color'] as String?) ?? 'Black',
      note: (j['note'] as String?) ?? '',
      laundry: LaundryStateX.fromCode(j['laundry'] as String?),
      createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
      lastWornAt: (j['lastWornAt'] as String?) == null ? null : DateTime.tryParse(j['lastWornAt'] as String),
      warmths: ((j['warmths'] as List?) ?? const [2]).map((e) => (e as num).toInt()).toList(),
      occasions: ((j['occasions'] as List?) ?? const ['casual']).map((e) => e.toString()).toList(),
      seasons: ((j['seasons'] as List?) ??
              const ['winter', 'spring', 'summer', 'autumn'])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

class OutfitLog {
  final String id; // unique log id
  final DateTime wornAt;
  final List<String> itemIds; // sorted unique
  final String event; // sport/cafe/office/dinner/formal
  final String? weatherBucket; // Cold/Mild/Hot
  final double? tempC;
  final bool? raining;

  /// feedback: -1 dislike, 0 neutral, 1 like
  final int feedback;

  /// favorite snapshot for that day (optional)
  final bool favorite;

  const OutfitLog({
    required this.id,
    required this.wornAt,
    required this.itemIds,
    required this.event,
    this.weatherBucket,
    this.tempC,
    this.raining,
    this.feedback = 0,
    this.favorite = false,
  });

  String get comboKey => OutfitKey.fromIds(itemIds).key;

  OutfitLog copyWith({
    String? id,
    DateTime? wornAt,
    List<String>? itemIds,
    String? event,
    String? weatherBucket,
    double? tempC,
    bool? raining,
    int? feedback,
    bool? favorite,
  }) {
    return OutfitLog(
      id: id ?? this.id,
      wornAt: wornAt ?? this.wornAt,
      itemIds: itemIds ?? this.itemIds,
      event: event ?? this.event,
      weatherBucket: weatherBucket ?? this.weatherBucket,
      tempC: tempC ?? this.tempC,
      raining: raining ?? this.raining,
      feedback: feedback ?? this.feedback,
      favorite: favorite ?? this.favorite,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'wornAt': wornAt.toIso8601String(),
        'itemIds': itemIds,
        'event': event,
        'weatherBucket': weatherBucket,
        'tempC': tempC,
        'raining': raining,
        'feedback': feedback,
        'favorite': favorite,
      };

  factory OutfitLog.fromJson(Map<String, dynamic> j) {
    final rawIds = ((j['itemIds'] as List?) ?? const []).map((e) => e.toString()).toSet().toList()..sort();
    return OutfitLog(
      id: (j['id'] as String?) ?? _uid(),
      wornAt: DateTime.tryParse((j['wornAt'] as String?) ?? '') ?? DateTime.now(),
      itemIds: rawIds,
      event: (j['event'] as String?) ?? 'cafe',
      weatherBucket: j['weatherBucket'] as String?,
      tempC: (j['tempC'] as num?)?.toDouble(),
      raining: j['raining'] as bool?,
      feedback: ((j['feedback'] as num?)?.toInt()) ?? 0,
      favorite: (j['favorite'] as bool?) ?? false,
    );
  }
}

class OutfitKey {
  final List<String> ids;
  final String key;
  const OutfitKey._(this.ids, this.key);

  factory OutfitKey.fromSuggestion(OutfitSuggestion s) {
    final ids = <String>{
      s.top.id,
      s.bottom.id,
      if (s.outer != null) s.outer!.id,
      if (s.shoes != null) s.shoes!.id,
      if (s.accessory != null) s.accessory!.id,
    }.toList()
      ..sort();
    return OutfitKey._(ids, ids.join('|'));
  }

  factory OutfitKey.fromIds(List<String> ids) {
    final xs = ids.toSet().toList()..sort();
    return OutfitKey._(xs, xs.join('|'));
  }
}

/* -------------------------------------------------------------------------- */
/*                                   STORES                                   */
/* -------------------------------------------------------------------------- */

class OutfitStore extends ChangeNotifier {
  final List<ClothingItem> _items = [];
  final List<OutfitLog> _history = [];

  /// favorite combos by key
  final Set<String> _favorites = {};

  /// learning weights (simple, fast, offline)
  final Map<String, double> _itemAffinity = {}; // itemId -> weight
  final Map<String, double> _comboAffinity = {}; // comboKey -> weight

  /// app settings persisted in the same db file
  final Map<String, dynamic> _settings = {};

  Directory? _imagesDir;
  File? _dbFile;
  bool _inited = false;

  bool _busy = false;
  bool get busy => _busy;

  List<ClothingItem> get items => List.unmodifiable(_items);
  List<OutfitLog> get history => List.unmodifiable(_history);
  Set<String> get favorites => Set.unmodifiable(_favorites);


bool getFlag(String key, {bool defaultValue = false}) {
  final v = _settings[key];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.toLowerCase() == 'true' || v == '1';
  return defaultValue;
}

Future<void> setFlag(String key, bool value) async {
  _settings[key] = value;
  await _persist();
  notifyListeners();
}


  ClothingItem? byId(String id) {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx == -1) return null;
    return _items[idx];
  }

  Future<void> _init() async {
    if (_inited) return;
    final docs = await getApplicationDocumentsDirectory();
    _imagesDir = Directory(p.join(docs.path, 'outfit_images'));
    if (!await _imagesDir!.exists()) await _imagesDir!.create(recursive: true);

    _dbFile = File(p.join(docs.path, 'outfit_db.json'));
    _inited = true;
  }

  Future<void> load() async {
    await _init();
    if (!await _dbFile!.exists()) return;

    try {
      final raw = await _dbFile!.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);

      if (decoded is Map<String, dynamic>) {
        final itemsList = (decoded['items'] as List?) ?? const [];
        final histList = (decoded['history'] as List?) ?? const [];
        final favList = (decoded['favorites'] as List?) ?? const [];
        final itemAff = (decoded['itemAffinity'] as Map?) ?? const {};
        final comboAff = (decoded['comboAffinity'] as Map?) ?? const {};
        final settings = (decoded['settings'] as Map?) ?? const {};

        _items
          ..clear()
          ..addAll(itemsList.map((e) => ClothingItem.fromJson((e as Map).cast<String, dynamic>())));

        _history
          ..clear()
          ..addAll(histList.map((e) => OutfitLog.fromJson((e as Map).cast<String, dynamic>())));

        _favorites
          ..clear()
          ..addAll(favList.map((e) => e.toString()));

        _itemAffinity
          ..clear()
          ..addAll(itemAff.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())));

        _comboAffinity
          ..clear()
          ..addAll(comboAff.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())));

        _settings
          ..clear()
          ..addAll(settings.map((k, v) => MapEntry(k.toString(), v)));
      }
    } catch (_) {
      _items.clear();
      _history.clear();
      _favorites.clear();
      _itemAffinity.clear();
      _comboAffinity.clear();
    }

    _sanitize();
    notifyListeners();
  }

  void _sanitize() {
    // Keep learning weights bounded
    _itemAffinity.removeWhere((k, _) => byId(k) == null);
    _itemAffinity.updateAll((k, v) => v.clamp(-3.0, 3.0));
    _comboAffinity.updateAll((k, v) => v.clamp(-3.0, 3.0));
  }

  Future<void> _persist() async {
    await _init();
    final payload = {
      'items': _items.map((e) => e.toJson()).toList(),
      'history': _history.map((e) => e.toJson()).toList(),
      'favorites': _favorites.toList(),
      'itemAffinity': _itemAffinity,
      'comboAffinity': _comboAffinity,
      'settings': _settings,
    };

    final dst = _dbFile!;
    final tmp = File('${dst.path}.tmp');
    final json = jsonEncode(payload);

    try {
      await tmp.writeAsString(json, flush: true);
      if (await dst.exists()) {
        try {
          await dst.delete();
        } catch (_) {}
      }
      await tmp.rename(dst.path);
    } catch (_) {
      try {
        await dst.writeAsString(json, flush: true);
      } catch (_) {}
    }
  }

  /* ------------------------------ Images I/O ------------------------------ */

  Future<String> savePickedImageToAppDir({required XFile picked, required String id}) async {
    await _init();
    final ext0 = p.extension(picked.path);
    final ext = ext0.isEmpty ? '.jpg' : ext0;
    final dstPath = p.join(_imagesDir!.path, '$id$ext');

    try {
      final src = File(picked.path);
      if (await src.exists()) {
        await src.copy(dstPath);
      } else {
        final bytes = await picked.readAsBytes();
        await File(dstPath).writeAsBytes(bytes, flush: true);
      }
    } catch (_) {
      final bytes = await picked.readAsBytes();
      await File(dstPath).writeAsBytes(bytes, flush: true);
    }

    return dstPath;
  }

  Future<String> replaceImage({required String id, required XFile picked, required String oldImagePath}) async {
    final newPath = await savePickedImageToAppDir(picked: picked, id: id);
    if (newPath != oldImagePath) {
      try {
        final old = File(oldImagePath);
        if (await old.exists()) await old.delete();
      } catch (_) {}
    }
    return newPath;
  }

  /* ------------------------------ Wardrobe CRUD ------------------------------ */

  Future<void> addItem(ClothingItem item) async {
    _items.insert(0, item);
    notifyListeners();
    await _persist();
  }

  Future<void> updateItem(ClothingItem updated) async {
    final idx = _items.indexWhere((e) => e.id == updated.id);
    if (idx == -1) return;
    _items[idx] = updated;
    notifyListeners();
    await _persist();
  }

  Future<void> deleteItem(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    final removed = _items.removeAt(idx);

    // delete image
    try {
      final f = File(removed.imagePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}

    // remove from history and favorites keys
    for (var i = _history.length - 1; i >= 0; i--) {
      final h = _history[i];
      if (!h.itemIds.contains(id)) continue;
      final newIds = h.itemIds.where((x) => x != id).toList()..sort();
      if (newIds.isEmpty) {
        _history.removeAt(i);
      } else {
        _history[i] = h.copyWith(itemIds: newIds);
      }
    }

    _favorites.removeWhere((k) => k.split('|').contains(id));
    _sanitize();

    notifyListeners();
    await _persist();
  }

  /* ------------------------------ Favorites ------------------------------ */

  bool isFavoriteKey(String key) => _favorites.contains(key);

  Future<void> toggleFavoriteKey(String key) async {
    if (_favorites.contains(key)) {
      _favorites.remove(key);
      // slight negative to reduce repeated same picks if user unfavorites
      _comboAffinity[key] = ((_comboAffinity[key] ?? 0) - 0.2).clamp(-3.0, 3.0);
    } else {
      _favorites.add(key);
      _comboAffinity[key] = ((_comboAffinity[key] ?? 0) + 0.3).clamp(-3.0, 3.0);
    }
    notifyListeners();
    await _persist();
  }

  /* ------------------------------ Feedback (Learning) ------------------------------ */

  Future<void> setHistoryFeedback(String logId, int feedback) async {
    final idx = _history.indexWhere((e) => e.id == logId);
    if (idx == -1) return;

    final old = _history[idx];
    final newFb = feedback.clamp(-1, 1);

    // remove previous contribution
    _applyLearning(old.itemIds, old.comboKey, old.feedback, undo: true);

    // apply new
    _history[idx] = old.copyWith(feedback: newFb);
    _applyLearning(old.itemIds, old.comboKey, newFb, undo: false);

    notifyListeners();
    await _persist();
  }

  Future<void> toggleHistoryFavorite(String logId) async {
    final idx = _history.indexWhere((e) => e.id == logId);
    if (idx == -1) return;
    final old = _history[idx];
    final next = !old.favorite;
    _history[idx] = old.copyWith(favorite: next);

    if (next) {
      _favorites.add(old.comboKey);
      _comboAffinity[old.comboKey] = ((_comboAffinity[old.comboKey] ?? 0) + 0.2).clamp(-3.0, 3.0);
    } else {
      // don't auto-remove from favorites list here (user might have favorited from planner)
      _comboAffinity[old.comboKey] = ((_comboAffinity[old.comboKey] ?? 0) - 0.1).clamp(-3.0, 3.0);
    }

    notifyListeners();
    await _persist();
  }

  void _applyLearning(List<String> itemIds, String comboKey, int feedback, {required bool undo}) {
    final sign = undo ? -1.0 : 1.0;
    final fb = feedback.clamp(-1, 1).toDouble();

    // item affinity
    for (final id in itemIds) {
      _itemAffinity[id] = ((_itemAffinity[id] ?? 0) + sign * fb * 0.25).clamp(-3.0, 3.0);
    }
    // combo affinity
    _comboAffinity[comboKey] = ((_comboAffinity[comboKey] ?? 0) + sign * fb * 0.45).clamp(-3.0, 3.0);
  }

  /* ------------------------------ History ------------------------------ */

  Future<bool> logOutfit({
    required List<String> itemIds,
    required String event,
    String? weatherBucket,
    double? tempC,
    bool? raining,
    bool markFavorite = false,
  }) async {
    if (_busy) return false;
    _busy = true;
    try {
      if (itemIds.isEmpty) return false;
      final when = DateTime.now();

      final ids = itemIds.toSet().toList()..sort();
      final key = OutfitKey.fromIds(ids).key;

      // update lastWornAt
      for (final id in ids) {
        final idx = _items.indexWhere((e) => e.id == id);
        if (idx == -1) continue;
        _items[idx] = _items[idx].copyWith(lastWornAt: when);
      }

      // de-dup history: do not insert exact same combo twice
      final exists = _history.any((h) => h.comboKey == key);

      if (!exists) {
        _history.insert(
          0,
          OutfitLog(
            id: _uid(),
            wornAt: when,
            itemIds: ids,
            event: event,
            weatherBucket: weatherBucket,
            tempC: tempC,
            raining: raining,
            favorite: markFavorite,
          ),
        );
        if (_history.length > 400) _history.removeRange(400, _history.length);
      }

      // wear event learning: slight "cooldown pressure" so it doesn't spam same outfit
      _comboAffinity[key] = ((_comboAffinity[key] ?? 0) - 0.10).clamp(-3.0, 3.0);
      for (final id in ids) {
        _itemAffinity[id] = ((_itemAffinity[id] ?? 0) - 0.03).clamp(-3.0, 3.0);
      }

      if (markFavorite) _favorites.add(key);

      notifyListeners();
      await _persist();
      return !exists;
    } finally {
      _busy = false;
    }
  }

  Future<void> deleteHistory(String logId) async {
    final idx = _history.indexWhere((e) => e.id == logId);
    if (idx == -1) return;
    _history.removeAt(idx);
    notifyListeners();
    await _persist();
  }

  Future<void> clearHistory() async {
    _history.clear();
    notifyListeners();
    await _persist();
  }

  /* ------------------------------ Stats helpers ------------------------------ */

  int wearCountForItem(String itemId, {int? lastDays}) {
    final now = DateTime.now();
    final cutoff = lastDays == null ? null : now.subtract(Duration(days: lastDays));
    int c = 0;
    for (final h in _history) {
      if (cutoff != null && h.wornAt.isBefore(cutoff)) continue;
      if (h.itemIds.contains(itemId)) c++;
    }
    return c;
  }

  double itemAffinity(String itemId) => _itemAffinity[itemId] ?? 0.0;
  double comboAffinity(String key) => _comboAffinity[key] ?? 0.0;
}

/* -------------------------------------------------------------------------- */
/*                                  WEATHER                                   */
/* -------------------------------------------------------------------------- */

class WeatherNow {
  final DateTime time;
  final double temperatureC;
  final double windKmh;
  final double precipitationMm;
  final int weatherCode;
  const WeatherNow({
    required this.time,
    required this.temperatureC,
    required this.windKmh,
    required this.precipitationMm,
    required this.weatherCode,
  });
}

class WeatherHour {
  final DateTime time;
  final double temperatureC;
  final int precipitationProb; // 0-100
  final double precipitationMm;
  final double windKmh;
  final int weatherCode;
  const WeatherHour({
    required this.time,
    required this.temperatureC,
    required this.precipitationProb,
    required this.precipitationMm,
    required this.windKmh,
    required this.weatherCode,
  });
}

class WeatherStore extends ChangeNotifier {
  bool loading = false;
  String? error;

  WeatherNow? now;
  List<WeatherHour> hours = const [];

  String bucket = 'Mild'; // Cold/Mild/Hot
  int desiredWarmth = 2; // 1/2/3

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final pos = await _safeGetPosition();
      final (n, h) = await _fetchOpenMeteo(pos.latitude, pos.longitude);

      now = n;
      hours = h;

      final t = now?.temperatureC ?? 18.0;
      if (t <= 9) {
        bucket = 'Cold';
        desiredWarmth = 3;
      } else if (t >= 24) {
        bucket = 'Hot';
        desiredWarmth = 1;
      } else {
        bucket = 'Mild';
        desiredWarmth = 2;
      }

      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  static Future<Position> _safeGetPosition() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw Exception('Konum servisi kapalı');
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied) throw Exception('Konum izni reddedildi');
    if (perm == LocationPermission.deniedForever) throw Exception('Konum izni kalıcı reddedildi');

    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return last;

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low,
      timeLimit: const Duration(seconds: 25),
    );
  }

  static Future<(WeatherNow, List<WeatherHour>)> _fetchOpenMeteo(double lat, double lon) async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon'
      '&current=temperature_2m,precipitation,wind_speed_10m,weather_code'
      '&hourly=temperature_2m,precipitation_probability,precipitation,wind_speed_10m,weather_code'
      '&timezone=auto',
    );

    final res = await http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw Exception('Weather request failed: ${res.statusCode}');
    final j = jsonDecode(res.body) as Map<String, dynamic>;

    final cur = (j['current'] as Map).cast<String, dynamic>();
    final now = WeatherNow(
      time: DateTime.parse(cur['time'] as String),
      temperatureC: (cur['temperature_2m'] as num).toDouble(),
      precipitationMm: (cur['precipitation'] as num).toDouble(),
      windKmh: (cur['wind_speed_10m'] as num).toDouble(),
      weatherCode: (cur['weather_code'] as num).toInt(),
    );

    final hourly = (j['hourly'] as Map).cast<String, dynamic>();
    final times = (hourly['time'] as List).cast<dynamic>().map((e) => DateTime.parse(e.toString())).toList();
    final temps = (hourly['temperature_2m'] as List).cast<dynamic>().map((e) => (e as num).toDouble()).toList();
    final pop = (hourly['precipitation_probability'] as List).cast<dynamic>().map((e) => (e as num).toInt()).toList();
    final pr = (hourly['precipitation'] as List).cast<dynamic>().map((e) => (e as num).toDouble()).toList();
    final wind = (hourly['wind_speed_10m'] as List).cast<dynamic>().map((e) => (e as num).toDouble()).toList();
    final code = (hourly['weather_code'] as List).cast<dynamic>().map((e) => (e as num).toInt()).toList();

    final hours = <WeatherHour>[];
    for (var i = 0; i < min(times.length, 48); i++) {
      hours.add(
        WeatherHour(
          time: times[i],
          temperatureC: temps[i],
          precipitationProb: pop[i],
          precipitationMm: pr[i],
          windKmh: wind[i],
          weatherCode: code[i],
        ),
      );
    }

    return (now, hours);
  }
}

/* -------------------------------------------------------------------------- */
/*                               OUTFIT ENGINE                                */
/* -------------------------------------------------------------------------- */

class OutfitSuggestion {
  final ClothingItem top;
  final ClothingItem bottom;
  final ClothingItem? outer;
  final ClothingItem? shoes;
  final ClothingItem? accessory;
  final double score;
  final Map<String, double> breakdown;

  const OutfitSuggestion({
    required this.top,
    required this.bottom,
    required this.outer,
    required this.shoes,
    required this.accessory,
    required this.score,
    required this.breakdown,
  });
}

class OutfitEngine {
  static List<OutfitSuggestion> generate({
    required OutfitStore store,
    required WeatherStore weather,
    required String event,
    required Season season,
    int take = 5,
  }) {
    final desiredOcc = _desiredOccasionFromEvent(event);
    final bucket = weather.now == null ? 'Mild' : weather.bucket;
    final desiredWarmth = weather.now == null ? 2 : weather.desiredWarmth;
    final rainingNow = (weather.now?.precipitationMm ?? 0) > 0.2;

    // Only clean clothes. Strict by occasion; fallback.
    var pool = store.items
        .where((it) => it.laundry == LaundryState.ready && it.supportsOccasion(desiredOcc) && it.supportsSeason(season))
        .toList();
    if (pool.isEmpty) {
      pool = store.items.where((it) => it.laundry == LaundryState.ready && it.supportsSeason(season)).toList();
    }
    if (pool.isEmpty) return const [];

    final tops = pool.where((e) => e.category == 'TOP').toList();
    final bottoms = pool.where((e) => e.category == 'BOTTOM').toList();
    final outers = pool.where((e) => e.category == 'OUTER').toList();
    final shoes = pool.where((e) => e.category == 'SHOES').toList();
    final accs = pool.where((e) => e.category == 'ACCESSORY').toList();

    if (tops.isEmpty || bottoms.isEmpty) return const [];

    // pre-rank each bucket by itemScore
    int cmp(ClothingItem a, ClothingItem b) =>
        _itemScore(store, b, desiredWarmth, desiredOcc, bucket, rainingNow).compareTo(
          _itemScore(store, a, desiredWarmth, desiredOcc, bucket, rainingNow),
        );

    tops.sort(cmp);
    bottoms.sort(cmp);
    outers.sort(cmp);
    shoes.sort(cmp);
    accs.sort(cmp);

    final topTops = tops.take(7).toList();
    final topBottoms = bottoms.take(7).toList();
    final topShoes = shoes.take(5).toList();
    final topAcc = accs.take(4).toList();
    final topOuter = outers.take(5).toList();

    final allowOuter = bucket != 'Hot';
    final wantOuter = bucket == 'Cold' || rainingNow;

    final candidates = <OutfitSuggestion>[];

    for (final t in topTops) {
      for (final b in topBottoms) {
        final sh = topShoes.isEmpty ? null : topShoes.first;
        final ac = topAcc.isEmpty ? null : topAcc.first;

        ClothingItem? ot;
        if (allowOuter && topOuter.isNotEmpty) {
          ot = wantOuter ? topOuter.first : null;
        }

        final (score, breakdown) = _outfitScore(
          store: store,
          top: t,
          bottom: b,
          outer: ot,
          shoes: sh,
          accessory: ac,
          desiredWarmth: desiredWarmth,
          desiredOccasion: desiredOcc,
          weatherBucket: bucket,
          rainingNow: rainingNow,
        );

        candidates.add(
          OutfitSuggestion(
            top: t,
            bottom: b,
            outer: ot,
            shoes: sh,
            accessory: ac,
            score: score,
            breakdown: breakdown,
          ),
        );
      }
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));

    // pick distinct combos
    final picked = <OutfitSuggestion>[];
    final used = <String>{};
    for (final s in candidates) {
      final key = OutfitKey.fromSuggestion(s).key;
      if (used.add(key)) {
        picked.add(s);
        if (picked.length == take) break;
      }
    }
    return picked;
  }

  static String _desiredOccasionFromEvent(String e) {
    switch (e) {
      case 'sport':
        return 'sport';
      case 'office':
        return 'smart';
      case 'formal':
        return 'formal';
      case 'dinner':
        return 'smart';
      default:
        return 'casual';
    }
  }

  static double _itemScore(
    OutfitStore store,
    ClothingItem it,
    int desiredWarmth,
    String desiredOccasion,
    String weatherBucket,
    bool rainingNow,
  ) {
    double s = 0;

    // warmth match (closest selected)
    final diffs = it.warmths.isEmpty ? [100] : it.warmths.map((w) => (w - desiredWarmth).abs()).toList();
    final d = diffs.reduce(min);
    if (d == 0) s += 10;
    if (d == 1) s += 3;
    if (d >= 2) s -= 7;

    // occasion match
    if (it.supportsOccasion(desiredOccasion)) s += 7;

    // cooldown
    final lw = it.lastWornAt;
    if (lw != null) {
      final hours = DateTime.now().difference(lw).inHours;
      if (hours < 24) s -= 22;
      else if (hours < 48) s -= 12;
      else if (hours < 72) s -= 7;
      else if (hours < 168) s -= 3;
    }

    // recent usage penalty (last 7 days)
    final used7 = store.wearCountForItem(it.id, lastDays: 7);
    s -= min(used7 * 1.3, 6.0);

    // outer behavior
    if (it.category == 'OUTER') {
      if (weatherBucket == 'Cold' || rainingNow) s += 6;
      if (weatherBucket == 'Hot') s -= 50;
    }

    // color base: neutrals are flexible
    if (_isNeutral(it.color)) s += 1.3;

    // learning: item affinity
    s += store.itemAffinity(it.id) * 4.5;

    // small reward if never/rarely worn (new things)
    final totalUsed = store.wearCountForItem(it.id);
    if (totalUsed == 0) s += 2.0;

    return s;
  }

  static (double, Map<String, double>) _outfitScore({
    required OutfitStore store,
    required ClothingItem top,
    required ClothingItem bottom,
    required ClothingItem? outer,
    required ClothingItem? shoes,
    required ClothingItem? accessory,
    required int desiredWarmth,
    required String desiredOccasion,
    required String weatherBucket,
    required bool rainingNow,
  }) {
    final b = <String, double>{};
    double s = 0;

    final topS = _itemScore(store, top, desiredWarmth, desiredOccasion, weatherBucket, rainingNow);
    final botS = _itemScore(store, bottom, desiredWarmth, desiredOccasion, weatherBucket, rainingNow);
    s += topS + botS;
    b['Top'] = topS;
    b['Bottom'] = botS;

    if (shoes != null) {
      final shS = _itemScore(store, shoes, desiredWarmth, desiredOccasion, weatherBucket, rainingNow) * 0.70;
      s += shS;
      b['Shoes'] = shS;
    }
    if (accessory != null) {
      final acS = _itemScore(store, accessory, desiredWarmth, desiredOccasion, weatherBucket, rainingNow) * 0.40;
      s += acS;
      b['Acc'] = acS;
    }

    if (outer != null) {
      if (weatherBucket == 'Hot') return (-999, const {});
      final otS = _itemScore(store, outer, desiredWarmth, desiredOccasion, weatherBucket, rainingNow) * 0.80;
      s += otS;
      b['Outer'] = otS;
    } else {
      if (weatherBucket == 'Cold' || rainingNow) {
        s -= 6;
        b['NoOuterPenalty'] = -6;
      }
    }

    // color harmony matrix
    final harmony = _colorHarmonyScore(top.color, bottom.color, outer?.color, shoes?.color, accessory?.color);
    s += harmony;
    b['ColorHarmony'] = harmony;

    // combo learning + favorites
    final key = OutfitKey.fromIds([
      top.id,
      bottom.id,
      if (outer != null) outer.id,
      if (shoes != null) shoes.id,
      if (accessory != null) accessory.id,
    ]).key;

    final fav = store.isFavoriteKey(key) ? 3.5 : 0.0;
    final comboLearn = store.comboAffinity(key) * 7.0;
    s += fav + comboLearn;
    if (fav != 0) b['Favorite'] = fav;
    if (comboLearn != 0) b['LearnedCombo'] = comboLearn;

    return (s, b);
  }

  /* -------------------------- Color harmony matrix ------------------------- */

  static bool _isNeutral(String c) => const {'Black', 'White', 'Gray', 'Beige', 'Navy'}.contains(c);

  static String _groupOf(String c) {
    if (_isNeutral(c)) return 'neutral';
    const warm = {'Red', 'Orange', 'Yellow', 'Pink', 'Burgundy'};
    const cool = {'Blue', 'Green', 'Teal', 'Turquoise', 'Purple'};
    const earth = {'Brown', 'Khaki', 'Olive', 'Tan'};
    if (warm.contains(c)) return 'warm';
    if (cool.contains(c)) return 'cool';
    if (earth.contains(c)) return 'earth';
    return 'other';
  }

  static double _pairScore(String a, String b) {
    if (a == b) return 3.0;
    final ga = _groupOf(a);
    final gb = _groupOf(b);

    if (ga == 'neutral' || gb == 'neutral') return 2.3;
    if (ga == gb) return 1.4; // same vibe works
    if ((ga == 'warm' && gb == 'earth') || (ga == 'earth' && gb == 'warm')) return 1.9;
    if ((ga == 'cool' && gb == 'earth') || (ga == 'earth' && gb == 'cool')) return 1.7;
    if ((ga == 'warm' && gb == 'cool') || (ga == 'cool' && gb == 'warm')) return 0.6; // risky but possible
    return 0.0;
  }

  static double _colorHarmonyScore(String top, String bottom, String? outer, String? shoes, String? acc) {
    double s = 0;
    s += _pairScore(top, bottom);
    if (outer != null) s += _pairScore(outer, top) * 0.5;
    if (shoes != null) s += _pairScore(shoes, bottom) * 0.4;
    if (acc != null) s += _pairScore(acc, top) * 0.25;

    // small penalty if everything is loud and nothing neutral
    final colors = [top, bottom, if (outer != null) outer, if (shoes != null) shoes, if (acc != null) acc];
    final neutralCount = colors.where(_isNeutral).length;
    if (neutralCount == 0 && colors.length >= 3) s -= 1.2;

    return s;
  }
}

/* -------------------------------------------------------------------------- */
/*                                    UI                                      */
/* -------------------------------------------------------------------------- */

class HomePage extends StatelessWidget {
  final OutfitStore store;
  final WeatherStore weather;

  const HomePage({super.key, required this.store, required this.weather});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([store, weather]),
      builder: (_, __) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TopBar(
                    count: store.items.length,
                    weather: weather,
                    onTapWeather: () => _showWeatherSheet(context, weather),
                    onRefreshWeather: () => weather.refresh(),
                    onTapHistory: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => OutfitHistoryPage(store: store)),
                    ),
                    onTapFavorites: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => FavoritesPage(store: store)),
                    ),
                    onTapStats: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => StatsPage(store: store)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Hızlı Başlangıç',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _QuickPill(text: 'Kafe', icon: Icons.local_cafe_rounded, onTap: () => _openPlanner(context, 'cafe')),
                      _QuickPill(text: 'Spor', icon: Icons.fitness_center_rounded, onTap: () => _openPlanner(context, 'sport')),
                      _QuickPill(text: 'Ofis', icon: Icons.business_center_rounded, onTap: () => _openPlanner(context, 'office')),
                      _QuickPill(text: 'Akşam', icon: Icons.restaurant_rounded, onTap: () => _openPlanner(context, 'dinner')),
                      _QuickPill(text: 'Formal', icon: Icons.star_rounded, onTap: () => _openPlanner(context, 'formal')),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: LayoutBuilder(
                          builder: (context, c) {
                            // This panel must be scrollable on short screens; otherwise
                            // buttons + spacer will overflow (exactly the warning you saw).
                            return SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minHeight: c.maxHeight),
                                child: IntrinsicHeight(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      const Text(
                                        'Ne yapmak istiyorsun?',
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
                                      ),
                                      const SizedBox(height: 14),
                                      _PrimaryButton(
                                        text: 'Kıyafet Ekle',
                                        icon: Icons.add_photo_alternate_rounded,
                                        onTap: () async {
                                          final added = await Navigator.of(context).push<bool>(
                                            MaterialPageRoute(builder: (_) => AddEditClothingPage(store: store)),
                                          );
                                          if (added == true && context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Eklendi.')));
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 10),
                                      _PrimaryButton(
                                        text: 'Dolabım',
                                        icon: Icons.checkroom_rounded,
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute(builder: (_) => ClosetPage(store: store)),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      _PrimaryButton(
                                        text: 'Kombin Oluştur',
                                        icon: Icons.auto_awesome_rounded,
                                        onTap: () => _openPlanner(context, null),
                                      ),
                                      const SizedBox(height: 10),
                                      _PrimaryButton(
                                        text: 'Favoriler',
                                        icon: Icons.favorite_rounded,
                                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FavoritesPage(store: store))),
                                      ),
                                      const SizedBox(height: 10),
                                      _PrimaryButton(
                                        text: 'İstatistik',
                                        icon: Icons.insights_rounded,
                                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StatsPage(store: store))),
                                      ),
                                      const Spacer(),
                                      Text(
                                        'Not: Her şey cihaz içinde saklanır. İnternet sadece hava durumu için kullanılır.',
                                        style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openPlanner(BuildContext context, String? event) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutfitPlannerPage(store: store, weather: weather, presetEvent: event),
      ),
    );
  }

  void _showWeatherSheet(BuildContext context, WeatherStore weather) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1030),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _WeatherSheet(weather: weather),
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                              ADD / EDIT CLOTHING                            */
/* -------------------------------------------------------------------------- */

const kCategories = <String, String>{
  'TOP': 'Üst',
  'BOTTOM': 'Alt',
  'OUTER': 'Dış',
  'SHOES': 'Ayakkabı',
  'ACCESSORY': 'Aksesuar',
};

const kColors = <String>[
  'Black',
  'White',
  'Gray',
  'Beige',
  'Navy',
  'Blue',
  'Green',
  'Olive',
  'Brown',
  'Red',
  'Burgundy',
  'Orange',
  'Yellow',
  'Pink',
  'Purple',
  'Teal',
];

const kOccasions = <(String code, String label, IconData icon)>[
  ('casual', 'Günlük', Icons.coffee_rounded),
  ('sport', 'Spor', Icons.fitness_center_rounded),
  ('smart', 'Smart', Icons.business_center_rounded),
  ('formal', 'Formal', Icons.star_rounded),
];

class AddEditClothingPage extends StatefulWidget {
  final OutfitStore store;
  final ClothingItem? initial;

  const AddEditClothingPage({super.key, required this.store, this.initial});

  @override
  State<AddEditClothingPage> createState() => _AddEditClothingPageState();
}

class _AddEditClothingPageState extends State<AddEditClothingPage> {
  final _note = TextEditingController();
  XFile? _picked;

  late String _category;
  late String _color;
  late LaundryState _laundry;

  late Set<int> _warmths;
  late Set<String> _occasions;
  late Set<String> _seasons;

  @override
  void initState() {
    super.initState();
    final it = widget.initial;
    _category = it?.category ?? 'TOP';
    _color = it?.color ?? 'Black';
    _laundry = it?.laundry ?? LaundryState.ready;
    _note.text = it?.note ?? '';
    _warmths = (it?.warmths ?? [2]).toSet();
    _occasions = (it?.occasions ?? ['casual']).toSet();
    _seasons = (it?.seasons ?? ['winter', 'spring', 'summer', 'autumn']).toSet();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x == null) return;
    setState(() => _picked = x);
  }

  bool get _editing => widget.initial != null;

  @override
  Widget build(BuildContext context) {
    final it = widget.initial;
    final title = _editing ? 'Kıyafet Düzenle' : 'Kıyafet Ekle';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('Fotoğraf'),
                  const SizedBox(height: 10),
                  _ImagePickerTile(
                    imagePath: _picked?.path ?? it?.imagePath,
                    onTap: _pickImage,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle('Temel Bilgi'),
                  const SizedBox(height: 10),
                  _Dropdown<String>(
                    label: 'Kategori',
                    value: _category,
                    items: kCategories.keys.toList(),
                    itemLabel: (x) => kCategories[x] ?? x,
                    onChanged: (v) => setState(() => _category = v),
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<String>(
                    label: 'Renk',
                    value: _color,
                    items: kColors,
                    itemLabel: (x) => x,
                    onChanged: (v) => setState(() => _color = v),
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<LaundryState>(
                    label: 'Durum',
                    value: _laundry,
                    items: LaundryState.values,
                    itemLabel: (x) => x.label,
                    onChanged: (v) => setState(() => _laundry = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Not (opsiyonel)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle('Kalınlık'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _ToggleChip(
                        label: 'İnce',
                        icon: Icons.thermostat_outlined,
                        selected: _warmths.contains(1),
                        onTap: () => setState(() => _toggleInt(_warmths, 1)),
                      ),
                      _ToggleChip(
                        label: 'Orta',
                        icon: Icons.thermostat_rounded,
                        selected: _warmths.contains(2),
                        onTap: () => setState(() => _toggleInt(_warmths, 2)),
                      ),
                      _ToggleChip(
                        label: 'Kalın',
                        icon: Icons.thermostat_auto_rounded,
                        selected: _warmths.contains(3),
                        onTap: () => setState(() => _toggleInt(_warmths, 3)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Occasion'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final o in kOccasions)
                        _ToggleChip(
                          label: o.$2,
                          icon: o.$3,
                          selected: _occasions.contains(o.$1),
                          onTap: () => setState(() => _toggleStr(_occasions, o.$1)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Sezon'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final s in Season.values)
                        _ToggleChip(
                          label: s.label,
                          icon: Icons.wb_sunny_rounded,
                          selected: _seasons.contains(s.code),
                          onTap: () => setState(() => _toggleStr(_seasons, s.code)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _PrimaryButton(
            text: _editing ? 'Kaydet' : 'Ekle',
            icon: Icons.save_rounded,
            onTap: () async {
              if (!_editing && _picked == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fotoğraf seçmeden ekleyemezsin.')));
                return;
              }
              if (_warmths.isEmpty) _warmths.add(2);
              if (_occasions.isEmpty) _occasions.add('casual');
              if (_seasons.isEmpty) _seasons.addAll(['winter', 'spring', 'summer', 'autumn']);

              if (_editing) {
                final old = it!;
                String imgPath = old.imagePath;
                if (_picked != null) {
                  imgPath = await widget.store.replaceImage(id: old.id, picked: _picked!, oldImagePath: old.imagePath);
                }
                await widget.store.updateItem(
                  old.copyWith(
                    imagePath: imgPath,
                    imageName: _picked?.name ?? old.imageName,
                    category: _category,
                    color: _color,
                    note: _note.text,
                    laundry: _laundry,
                    warmths: _warmths.toList()..sort(),
                    occasions: _occasions.toList()..sort(),
                    seasons: _seasons.toList()..sort(),
                  ),
                );
                if (context.mounted) Navigator.pop(context, true);
                return;
              }

              final id = _uid();
              final imgPath = await widget.store.savePickedImageToAppDir(picked: _picked!, id: id);
              final item = ClothingItem(
                id: id,
                imagePath: imgPath,
                imageName: _picked!.name,
                category: _category,
                color: _color,
                note: _note.text,
                laundry: _laundry,
                createdAt: DateTime.now(),
                warmths: _warmths.toList()..sort(),
                occasions: _occasions.toList()..sort(),
                seasons: _seasons.toList()..sort(),
              );
              await widget.store.addItem(item);
              if (context.mounted) Navigator.pop(context, true);
            },
          ),
          if (_editing) ...[
            const SizedBox(height: 10),
            _PrimaryButton(
              text: 'Sil',
              icon: Icons.delete_rounded,
              danger: true,
              onTap: () async {
                final ok = await _confirm(context, title: 'Kıyafeti sil?', body: 'Bu kıyafet ve ilişkili geçmiş kayıtları silinecek.');
                if (ok != true) return;
                await widget.store.deleteItem(it!.id);
                if (context.mounted) Navigator.pop(context, true);
              },
            ),
          ],
        ],
      ),
    );
  }

  void _toggleInt(Set<int> s, int v) => s.contains(v) ? s.remove(v) : s.add(v);
  void _toggleStr(Set<String> s, String v) => s.contains(v) ? s.remove(v) : s.add(v);
}

/* -------------------------------------------------------------------------- */
/*                                   CLOSET                                   */
/* -------------------------------------------------------------------------- */

class ClosetPage extends StatefulWidget {
  final OutfitStore store;
  const ClosetPage({super.key, required this.store});

  @override
  State<ClosetPage> createState() => _ClosetPageState();
}

class _ClosetPageState extends State<ClosetPage> {
  String? _cat;
  String? _color;
  Season? _season;
  LaundryState? _laundry;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (_, __) {
        final items = widget.store.items.where((it) {
          if (_cat != null && it.category != _cat) return false;
          if (_color != null && it.color != _color) return false;
          if (_laundry != null && it.laundry != _laundry) return false;
          if (_season != null && !it.supportsSeason(_season!)) return false;
          return true;
        }).toList();

        return Scaffold(
          appBar: AppBar(
            title: const Text('Dolabım'),
            actions: [
              IconButton(
                tooltip: 'Filtre',
                onPressed: () => _openFilters(context),
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
          body: items.isEmpty
              ? Center(
                  child: Text(
                    'Hiç kıyafet yok.',
                    style: TextStyle(color: Colors.white.withOpacity(0.65)),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.88,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _ClosetTile(
                    item: items[i],
                    store: widget.store,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ClothingDetailPage(store: widget.store, itemId: items[i].id)),
                    ),
                  ),
                ),
        );
      },
    );
  }

  Future<void> _openFilters(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0B1030),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).padding.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SectionTitle('Filtreler'),
                  const SizedBox(height: 12),
                  _Dropdown<String?>(
                    label: 'Kategori',
                    value: _cat,
                    items: [null, ...kCategories.keys],
                    itemLabel: (x) => x == null ? 'Hepsi' : (kCategories[x] ?? x),
                    onChanged: (v) => setSheet(() => _cat = v),
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<String?>(
                    label: 'Renk',
                    value: _color,
                    items: [null, ...kColors],
                    itemLabel: (x) => x == null ? 'Hepsi' : x,
                    onChanged: (v) => setSheet(() => _color = v),
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<LaundryState?>(
                    label: 'Durum',
                    value: _laundry,
                    items: [null, ...LaundryState.values],
                    itemLabel: (x) => x == null ? 'Hepsi' : x.label,
                    onChanged: (v) => setSheet(() => _laundry = v),
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<Season?>(
                    label: 'Sezon',
                    value: _season,
                    items: [null, ...Season.values],
                    itemLabel: (x) => x == null ? 'Hepsi' : x.label,
                    onChanged: (v) => setSheet(() => _season = v),
                  ),
                  const SizedBox(height: 14),
                  _PrimaryButton(
                    text: 'Uygula',
                    icon: Icons.check_rounded,
                    onTap: () {
                      setState(() {});
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      setSheet(() {
                        _cat = null;
                        _color = null;
                        _season = null;
                        _laundry = null;
                      });
                    },
                    child: const Text('Sıfırla'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class ClothingDetailPage extends StatelessWidget {
  final OutfitStore store;
  final String itemId;

  const ClothingDetailPage({super.key, required this.store, required this.itemId});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        final it = store.byId(itemId);
        if (it == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Detay')),
            body: Center(child: Text('Bulunamadı', style: TextStyle(color: Colors.white.withOpacity(0.65)))),
          );
        }

        final used = store.wearCountForItem(it.id);
        final used7 = store.wearCountForItem(it.id, lastDays: 7);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Kıyafet'),
            actions: [
              IconButton(
                tooltip: 'Düzenle',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AddEditClothingPage(store: store, initial: it)),
                ),
                icon: const Icon(Icons.edit_rounded),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      AspectRatio(
                        aspectRatio: 1.2,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: _SafeFileImage(path: it.imagePath),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _Badge(text: kCategories[it.category] ?? it.category, icon: Icons.checkroom_rounded),
                          _Badge(text: it.color, icon: Icons.palette_rounded),
                          _Badge(text: it.laundry.label, icon: it.laundry.icon),
                          _Badge(text: it.warmths.map(_warmthName).join(', '), icon: Icons.thermostat_rounded),
                          _Badge(text: it.seasons.map((e) => SeasonX.fromCode(e).label).join(', '), icon: Icons.calendar_month_rounded),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (it.note.trim().isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(it.note, style: TextStyle(color: Colors.white.withOpacity(0.80))),
                        ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: _MiniStat(label: 'Toplam', value: '$used')),
                          const SizedBox(width: 10),
                          Expanded(child: _MiniStat(label: 'Son 7 gün', value: '$used7')),
                          const SizedBox(width: 10),
                          Expanded(child: _MiniStat(label: 'Affinity', value: store.itemAffinity(it.id).toStringAsFixed(2))),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _warmthName(int w) => w == 1 ? 'İnce' : (w == 2 ? 'Orta' : 'Kalın');
}

class _ClosetTile extends StatelessWidget {
  final ClothingItem item;
  final OutfitStore store;
  final VoidCallback onTap;

  const _ClosetTile({required this.item, required this.store, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final used7 = store.wearCountForItem(item.id, lastDays: 7);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: _GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _SafeFileImage(path: item.imagePath),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                kCategories[item.category] ?? item.category,
                style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
              ),
              const SizedBox(height: 4),
              Text(
                '${item.color} • ${item.laundry.label} • 7g:$used7',
                style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                 OUTFIT PLANNER                              */
/* -------------------------------------------------------------------------- */

class OutfitPlannerPage extends StatefulWidget {
  final OutfitStore store;
  final WeatherStore weather;
  final String? presetEvent;

  const OutfitPlannerPage({super.key, required this.store, required this.weather, this.presetEvent});

  @override
  State<OutfitPlannerPage> createState() => _OutfitPlannerPageState();
}

class _OutfitPlannerPageState extends State<OutfitPlannerPage> {
  late String _event;
  bool _autoSeason = true;
  Season _season = SeasonX.current();

  @override
  void initState() {
    super.initState();
    _event = widget.presetEvent ?? 'cafe';
    _season = SeasonX.current();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.store, widget.weather]),
      builder: (_, __) {
        final wx = widget.weather;
        final season = _autoSeason ? SeasonX.current() : _season;

        final suggestions = OutfitEngine.generate(
          store: widget.store,
          weather: wx,
          event: _event,
          season: season,
          take: 5,
        );

        return Scaffold(
          appBar: AppBar(
            title: const Text('Kombin Oluştur'),
            actions: [
              IconButton(
                tooltip: 'Hava yenile',
                onPressed: () => wx.refresh(),
                icon: const Icon(Icons.refresh_rounded),
              ),
              IconButton(
                tooltip: 'Favoriler',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FavoritesPage(store: widget.store))),
                icon: const Icon(Icons.favorite_rounded),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _WeatherInlineCard(weather: wx),
              const SizedBox(height: 12),
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('Ayarlar'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _SelectChip(label: 'Spor', icon: Icons.fitness_center_rounded, selected: _event == 'sport', onTap: () => setState(() => _event = 'sport')),
                          _SelectChip(label: 'Kafe', icon: Icons.local_cafe_rounded, selected: _event == 'cafe', onTap: () => setState(() => _event = 'cafe')),
                          _SelectChip(label: 'Ofis', icon: Icons.business_center_rounded, selected: _event == 'office', onTap: () => setState(() => _event = 'office')),
                          _SelectChip(label: 'Akşam', icon: Icons.restaurant_rounded, selected: _event == 'dinner', onTap: () => setState(() => _event = 'dinner')),
                          _SelectChip(label: 'Formal', icon: Icons.star_rounded, selected: _event == 'formal', onTap: () => setState(() => _event = 'formal')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _GlassCard(
                              child: SwitchListTile(
                                value: _autoSeason,
                                onChanged: (v) => setState(() => _autoSeason = v),
                                title: const Text('Sezon otomatik'),
                                subtitle: Text(_autoSeason ? 'Şu an: ${SeasonX.current().label}' : 'Manuel: ${_season.label}'),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (!_autoSeason) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (final s in Season.values)
                              _SelectChip(
                                label: s.label,
                                icon: Icons.wb_sunny_rounded,
                                selected: _season == s,
                                onTap: () => setState(() => _season = s),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Hedef kalınlık: ${_warmthName(wx.now == null ? 2 : wx.desiredWarmth)}  •  Hava: ${wx.now == null ? 'Mild' : wx.bucket}  •  Sezon: ${season.label}',
                        style: TextStyle(color: Colors.white.withOpacity(0.75)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (suggestions.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: Center(
                    child: Text(
                      'Kombin üretemedim.\nEn az 1 TOP ve 1 BOTTOM lazım (ve seçili sezonda temiz olmalı).',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withOpacity(0.6)),
                    ),
                  ),
                )
              else
                Column(
                  children: [
                    for (final s in suggestions) ...[
                      _OutfitCard(suggestion: s, store: widget.store, weather: wx, event: _event),
                      const SizedBox(height: 12),
                    ]
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  String _warmthName(int w) => w == 1 ? 'İnce' : (w == 2 ? 'Orta' : 'Kalın');
}

class _OutfitCard extends StatelessWidget {
  final OutfitSuggestion suggestion;
  final OutfitStore store;
  final WeatherStore weather;
  final String event;

  const _OutfitCard({
    required this.suggestion,
    required this.store,
    required this.weather,
    required this.event,
  });

  OutfitKey get _key => OutfitKey.fromSuggestion(suggestion);

  @override
  Widget build(BuildContext context) {
    final key = _key.key;
    final isFav = store.isFavoriteKey(key);

    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Skor: ${suggestion.score.toStringAsFixed(1)}',
                    style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
                  ),
                ),
                IconButton(
                  tooltip: isFav ? 'Favoriden çıkar' : 'Favoriye ekle',
                  onPressed: () => store.toggleFavoriteKey(key),
                  icon: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFav ? Colors.pinkAccent : null),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _OutfitSlot(label: 'Top', item: suggestion.top),
                _OutfitSlot(label: 'Bottom', item: suggestion.bottom),
                if (suggestion.outer != null) _OutfitSlot(label: 'Outer', item: suggestion.outer!),
                if (suggestion.shoes != null) _OutfitSlot(label: 'Shoes', item: suggestion.shoes!),
                if (suggestion.accessory != null) _OutfitSlot(label: 'Acc', item: suggestion.accessory!),
              ],
            ),
            const SizedBox(height: 12),
            _GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Skor detayı', style: TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: suggestion.breakdown.entries
                          .map((e) => _TinyBadge(text: '${e.key}: ${e.value.toStringAsFixed(1)}'))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _PrimaryButton(
                    text: 'Giydim',
                    icon: Icons.check_circle_rounded,
                    onTap: () async {
                      if (store.busy) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('İşleniyor...')));
                        return;
                      }
                      final added = await store.logOutfit(
                        itemIds: _key.ids,
                        event: event,
                        weatherBucket: weather.bucket,
                        tempC: weather.now?.temperatureC,
                        raining: (weather.now?.precipitationMm ?? 0) > 0.2,
                        markFavorite: isFav,
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(added ? 'Geçmişe eklendi' : 'Bu kombin zaten geçmişte var. Silmeden tekrar eklenmez.'),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _PrimaryButton(
                    text: 'Beğendim',
                    icon: Icons.thumb_up_rounded,
                    subtle: true,
                    onTap: () async {
                      // apply to learning without writing a fake history entry
                      // quickest way: create a hidden log entry? No.
                      // We update combo affinity directly.
                      store
                        .._comboAffinity[key] = ((store.comboAffinity(key) + 0.45).clamp(-3.0, 3.0))
                        ..notifyListeners();
                      // ignore persist latency; do it safely
                      // (private access: same library file)
                      await store._persist();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not alındı (öğreniyor).')));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PrimaryButton(
                    text: 'Beğenmedim',
                    icon: Icons.thumb_down_rounded,
                    subtle: true,
                    danger: true,
                    onTap: () async {
                      store
                        .._comboAffinity[key] = ((store.comboAffinity(key) - 0.55).clamp(-3.0, 3.0))
                        ..notifyListeners();
                      await store._persist();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not alındı (öğreniyor).')));
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OutfitSlot extends StatelessWidget {
  final String label;
  final ClothingItem item;

  const _OutfitSlot({required this.label, required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _SafeFileImage(path: item.imagePath),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.45)),
                child: Text(
                  '$label\n${item.color}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                  FAVORITES                                  */
/* -------------------------------------------------------------------------- */

class FavoritesPage extends StatelessWidget {
  final OutfitStore store;
  const FavoritesPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        final favs = store.favorites.toList();
        favs.sort();
        return Scaffold(
          appBar: AppBar(title: const Text('Favoriler')),
          body: favs.isEmpty
              ? Center(
                  child: Text(
                    'Favori kombin yok.',
                    style: TextStyle(color: Colors.white.withOpacity(0.65)),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  itemCount: favs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final key = favs[i];
                    final ids = key.split('|');
                    final items = ids.map(store.byId).whereType<ClothingItem>().toList();
                    return _GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Favori Kombin ${i + 1}',
                                    style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Favoriden çıkar',
                                  onPressed: () => store.toggleFavoriteKey(key),
                                  icon: const Icon(Icons.favorite_rounded, color: Colors.pinkAccent),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final it in items) _HistorySlot(item: it),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _PrimaryButton(
                              text: 'Bu kombini giydim',
                              icon: Icons.check_circle_rounded,
                              onTap: () async {
                                final ok = await store.logOutfit(itemIds: ids, event: 'cafe', markFavorite: true);
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(ok ? 'Geçmişe eklendi' : 'Zaten geçmişte var.')),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                   HISTORY                                   */
/* -------------------------------------------------------------------------- */

class OutfitHistoryPage extends StatelessWidget {
  final OutfitStore store;
  const OutfitHistoryPage({super.key, required this.store});

  String _eventLabel(String e) {
    switch (e) {
      case 'sport':
        return 'Spor';
      case 'office':
        return 'Ofis';
      case 'dinner':
        return 'Akşam';
      case 'formal':
        return 'Formal';
      default:
        return 'Kafe';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        final logs = store.history;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Geçmiş'),
            actions: [
              if (logs.isNotEmpty)
                IconButton(
                  tooltip: 'Geçmişi temizle',
                  onPressed: () async {
                    final ok = await _confirm(context, title: 'Geçmişi temizle?', body: 'Tüm kombin geçmişi silinecek.');
                    if (ok == true) {
                      await store.clearHistory();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Geçmiş temizlendi')));
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
            ],
          ),
          body: logs.isEmpty
              ? Center(
                  child: Text(
                    'Henüz geçmiş yok.\nKombin sayfasında "Giydim" deyince burada görünür.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withOpacity(0.65)),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  itemCount: logs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final log = logs[i];
                    final log0 = log!;

        final dt = log0.wornAt;
                    final date = '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
                    final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

                    final meta = <String>[
                      _eventLabel(log.event),
                      if (log.tempC != null) '${log.tempC!.toStringAsFixed(0)}°',
                      if (log.weatherBucket != null) log.weatherBucket!,
                      if (log.raining == true) 'Yağış',
                    ].join(' • ');

                    final items = log.itemIds.map(store.byId).whereType<ClothingItem>().toList();

                    return InkWell(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HistoryDetailPage(store: store, logId: log.id))),
                      borderRadius: BorderRadius.circular(18),
                      child: _GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '$date  $time',
                                      style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
                                    ),
                                  ),
                                  _FeedbackIcon(feedback: log.feedback),
                                  const SizedBox(width: 6),
                                  IconButton(
                                    tooltip: 'Sil',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () async {
                                      final ok = await _confirm(context, title: 'Kombini sil?', body: 'Bu kayıt geçmişten kaldırılacak.');
                                      if (ok == true) {
                                        await store.deleteHistory(log.id);
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kombin silindi')));
                                      }
                                    },
                                    icon: const Icon(Icons.delete_outline_rounded),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(meta, style: TextStyle(color: Colors.white.withOpacity(0.70))),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  for (final it in items) _HistorySlot(item: it),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class HistoryDetailPage extends StatelessWidget {
  final OutfitStore store;
  final String logId;
  const HistoryDetailPage({super.key, required this.store, required this.logId});

  String _eventLabel(String e) {
    switch (e) {
      case 'sport':
        return 'Spor';
      case 'office':
        return 'Ofis';
      case 'dinner':
        return 'Akşam';
      case 'formal':
        return 'Formal';
      default:
        return 'Kafe';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        OutfitLog? log;
        for (final h in store.history) { if (h.id == logId) { log = h; break; } }
        if (log == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Detay')),
            body: Center(child: Text('Bulunamadı', style: TextStyle(color: Colors.white.withOpacity(0.65)))),
          );
        }

        final log0 = log!;

        final dt = log0.wornAt;
        final date = '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
        final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        final meta = <String>[
          _eventLabel(log0.event),
          if (log0.tempC != null) '${log0.tempC!.toStringAsFixed(0)}°',
          if (log0.weatherBucket != null) log0.weatherBucket!,
          if (log0.raining == true) 'Yağış',
        ].join(' • ');

        final items = log0.itemIds.map(store.byId).whereType<ClothingItem>().toList();
        final isFav = store.isFavoriteKey(log0.comboKey);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Kombin Detayı'),
            actions: [
              IconButton(
                tooltip: isFav ? 'Favoriden çıkar' : 'Favoriye ekle',
                onPressed: () => store.toggleFavoriteKey(log0.comboKey),
                icon: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFav ? Colors.pinkAccent : null),
              ),
              IconButton(
                tooltip: 'Sil',
                onPressed: () async {
                  final ok = await _confirm(context, title: 'Sil?', body: 'Bu kayıt silinecek.');
                  if (ok == true) {
                    await store.deleteHistory(log0.id);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$date  $time', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
                      const SizedBox(height: 6),
                      Text(meta, style: TextStyle(color: Colors.white.withOpacity(0.70))),
                      const SizedBox(height: 10),
                      Wrap(spacing: 10, runSpacing: 10, children: [for (final it in items) _HistorySlot(item: it)]),
                      const SizedBox(height: 12),
                      const _SectionTitle('Feedback'),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _PrimaryButton(
                              text: 'Beğendim',
                              icon: Icons.thumb_up_rounded,
                              subtle: true,
                              onTap: () => store.setHistoryFeedback(log0.id, 1),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _PrimaryButton(
                              text: 'Nötr',
                              icon: Icons.remove_rounded,
                              subtle: true,
                              onTap: () => store.setHistoryFeedback(log0.id, 0),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _PrimaryButton(
                              text: 'Beğenmedim',
                              icon: Icons.thumb_down_rounded,
                              subtle: true,
                              danger: true,
                              onTap: () => store.setHistoryFeedback(log0.id, -1),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Öğrenme (combo affinity): ${store.comboAffinity(log0.comboKey).toStringAsFixed(2)}',
                        style: TextStyle(color: Colors.white.withOpacity(0.70)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HistorySlot extends StatelessWidget {
  final ClothingItem item;
  const _HistorySlot({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      height: 92,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _SafeFileImage(path: item.imagePath),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.45)),
                child: Text(
                  item.category,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedbackIcon extends StatelessWidget {
  final int feedback;
  const _FeedbackIcon({required this.feedback});

  @override
  Widget build(BuildContext context) {
    if (feedback > 0) return const Icon(Icons.thumb_up_rounded, color: Colors.lightGreenAccent);
    if (feedback < 0) return const Icon(Icons.thumb_down_rounded, color: Colors.redAccent);
    return Icon(Icons.horizontal_rule_rounded, color: Colors.white.withOpacity(0.45));
  }
}

/* -------------------------------------------------------------------------- */
/*                                   STATS                                    */
/* -------------------------------------------------------------------------- */

class StatsPage extends StatelessWidget {
  final OutfitStore store;
  const StatsPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        final items = store.items;
        final logs = store.history;

        final totalWears = logs.length;
        final liked = logs.where((e) => e.feedback > 0).length;
        final disliked = logs.where((e) => e.feedback < 0).length;
        final neutral = totalWears - liked - disliked;

        final colorCounts = <String, int>{};
        for (final it in items) {
          colorCounts[it.color] = (colorCounts[it.color] ?? 0) + 1;
        }
        final topColors = colorCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

        final itemWearCounts = <String, int>{};
        for (final h in logs) {
          for (final id in h.itemIds) {
            itemWearCounts[id] = (itemWearCounts[id] ?? 0) + 1;
          }
        }
        final topWorn = itemWearCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

        final bucketCounts = <String, int>{};
        for (final h in logs) {
          final b = h.weatherBucket ?? 'Unknown';
          bucketCounts[b] = (bucketCounts[b] ?? 0) + 1;
        }
        final buckets = bucketCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

        return Scaffold(
          appBar: AppBar(title: const Text('İstatistik')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(child: _MiniStat(label: 'Kıyafet', value: '${items.length}')),
                      const SizedBox(width: 10),
                      Expanded(child: _MiniStat(label: 'Kombin geçmişi', value: '$totalWears')),
                      const SizedBox(width: 10),
                      Expanded(child: _MiniStat(label: 'Favori', value: '${store.favorites.length}')),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('Feedback dağılımı'),
                      const SizedBox(height: 10),
                      _BarRow(label: 'Beğendim', value: liked, max: max(1, totalWears)),
                      _BarRow(label: 'Nötr', value: neutral, max: max(1, totalWears)),
                      _BarRow(label: 'Beğenmedim', value: disliked, max: max(1, totalWears)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('En çok kullanılan renkler'),
                      const SizedBox(height: 10),
                      for (final e in topColors.take(6)) _BarRow(label: e.key, value: e.value, max: max(1, topColors.first.value)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('En çok giyilen parçalar'),
                      const SizedBox(height: 10),
                      if (topWorn.isEmpty)
                        Text('Henüz yok.', style: TextStyle(color: Colors.white.withOpacity(0.65)))
                      else
                        for (final e in topWorn.take(6))
                          _BarRow(
                            label: store.byId(e.key)?.category ?? e.key,
                            value: e.value,
                            max: max(1, topWorn.first.value),
                          ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('Hava bucket kullanımı'),
                      const SizedBox(height: 10),
                      if (buckets.isEmpty)
                        Text('Henüz yok.', style: TextStyle(color: Colors.white.withOpacity(0.65)))
                      else
                        for (final e in buckets.take(6)) _BarRow(label: e.key, value: e.value, max: max(1, buckets.first.value)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BarRow extends StatelessWidget {
  final String label;
  final int value;
  final int max;

  const _BarRow({required this.label, required this.value, required this.max});

  @override
  Widget build(BuildContext context) {
    final frac = max <= 0 ? 0.0 : value / max;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(label, style: TextStyle(color: Colors.white.withOpacity(0.80)))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: frac.clamp(0.0, 1.0),
                minHeight: 10,
                backgroundColor: Colors.white.withOpacity(0.08),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 30, child: Text('$value', textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                   WEATHER UI                               */
/* -------------------------------------------------------------------------- */

class _WeatherInlineCard extends StatelessWidget {
  final WeatherStore weather;
  const _WeatherInlineCard({required this.weather});

  @override
  Widget build(BuildContext context) {
    final now = weather.now;
    final t = now?.temperatureC;
    final rain = now?.precipitationMm ?? 0;
    final wind = now?.windKmh;

    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.cloud_rounded, color: Color(0xFF00E5FF)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                weather.loading
                    ? 'Hava yükleniyor...'
                    : (weather.error != null
                        ? 'Hava hatası: ${weather.error}'
                        : 'Şu an: ${t?.toStringAsFixed(0) ?? '-'}° • ${weather.bucket} • Yağış: ${rain.toStringAsFixed(1)}mm • Rüzgar: ${wind?.toStringAsFixed(0) ?? '-'} km/h'),
                style: TextStyle(color: Colors.white.withOpacity(0.75)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeatherSheet extends StatelessWidget {
  final WeatherStore weather;
  const _WeatherSheet({required this.weather});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: weather,
      builder: (_, __) {
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SectionTitle('Hava Durumu'),
              const SizedBox(height: 12),
              _WeatherInlineCard(weather: weather),
              const SizedBox(height: 12),
              if (weather.hours.isNotEmpty) ...[
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Saatlik (48h)', style: TextStyle(fontWeight: FontWeight.w900)),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 110,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: weather.hours.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) {
                      final h = weather.hours[i];
                      final time = '${h.time.hour.toString().padLeft(2, '0')}:00';
                      return _GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(time, style: TextStyle(color: Colors.white.withOpacity(0.75))),
                              const SizedBox(height: 6),
                              Text('${h.temperatureC.toStringAsFixed(0)}°', style: const TextStyle(fontWeight: FontWeight.w900)),
                              const SizedBox(height: 6),
                              Text('Yağış %${h.precipitationProb}', style: TextStyle(color: Colors.white.withOpacity(0.70), fontSize: 12)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _PrimaryButton(text: 'Yenile', icon: Icons.refresh_rounded, onTap: () => weather.refresh()),
            ],
          ),
        );
      },
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                  UI PARTS                                  */
/* -------------------------------------------------------------------------- */

class _TopBar extends StatelessWidget {
  final int count;
  final WeatherStore weather;
  final VoidCallback onTapWeather;
  final VoidCallback onRefreshWeather;
  final VoidCallback onTapHistory;
  final VoidCallback onTapFavorites;
  final VoidCallback onTapStats;

  const _TopBar({
    required this.count,
    required this.weather,
    required this.onTapWeather,
    required this.onRefreshWeather,
    required this.onTapHistory,
    required this.onTapFavorites,
    required this.onTapStats,
  });

  @override
  Widget build(BuildContext context) {
    final temp = weather.now?.temperatureC;
    final label = weather.loading ? '...' : (temp == null ? 'Hava' : '${temp.toStringAsFixed(0)}°');

    // NOTE: This bar must never squeeze the title into a tiny width (it makes the
    // text wrap letter-by-letter like in your screenshot). So we allow horizontal
    // scrolling instead of forcing everything into one row width.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          const Text(
            'Outfit Studio',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
          ),
          const SizedBox(width: 12),
          _PillButton(text: label, icon: Icons.cloud_rounded, onTap: onTapWeather, onLongPress: onRefreshWeather),
          const SizedBox(width: 10),
          _PillButton(text: 'Fav', icon: Icons.favorite_rounded, onTap: onTapFavorites),
          const SizedBox(width: 10),
          _PillButton(text: 'Stats', icon: Icons.insights_rounded, onTap: onTapStats),
          const SizedBox(width: 10),
          _PillButton(text: 'His', icon: Icons.history_rounded, onTap: onTapHistory),
          const SizedBox(width: 10),
          _PillButton(text: '$count', icon: Icons.checkroom_rounded, onTap: () {}),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _PillButton({required this.text, required this.icon, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
          ],
        ),
      ),
    );
  }
}

class _QuickPill extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;

  const _QuickPill({required this.text, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
          ],
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: child,
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final bool subtle;

  const _PrimaryButton({required this.text, required this.icon, required this.onTap, this.danger = false, this.subtle = false});

  @override
  Widget build(BuildContext context) {
    final bg = subtle
        ? Colors.white.withOpacity(0.06)
        : (danger ? Colors.redAccent.withOpacity(0.22) : const Color(0xFF00E5FF).withOpacity(0.18));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: danger ? Colors.redAccent : const Color(0xFF00E5FF)),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _SelectChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SelectChip({required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = selected ? const Color(0xFF00E5FF).withOpacity(0.18) : Colors.white.withOpacity(0.06);
    final br = selected ? const Color(0xFF00E5FF).withOpacity(0.55) : Colors.white.withOpacity(0.10);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: br),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ToggleChip({required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = selected ? const Color(0xFF00E5FF).withOpacity(0.18) : Colors.white.withOpacity(0.06);
    final br = selected ? const Color(0xFF00E5FF).withOpacity(0.55) : Colors.white.withOpacity(0.10);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: br),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)));
  }
}

class _TinyBadge extends StatelessWidget {
  final String text;
  const _TinyBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Text(text, style: TextStyle(color: Colors.white.withOpacity(0.80), fontSize: 12)),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Badge({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        child: Column(
          children: [
            Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFFEAF0FF))),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T> onChanged;

  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      value: value,
      items: items.map((x) => DropdownMenuItem(value: x, child: Text(itemLabel(x)))).toList(),
      onChanged: (v) {
        if (v == null) return;
        onChanged(v);
      },
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _ImagePickerTile extends StatelessWidget {
  final String? imagePath;
  final VoidCallback onTap;

  const _ImagePickerTile({required this.imagePath, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final has = imagePath != null && imagePath!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white.withOpacity(0.06),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: has
              ? _SafeFileImage(path: imagePath!)
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add_photo_alternate_rounded, size: 34, color: Color(0xFF00E5FF)),
                      const SizedBox(height: 8),
                      Text('Fotoğraf seç', style: TextStyle(color: Colors.white.withOpacity(0.75))),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _SafeFileImage extends StatelessWidget {
  final String path;
  const _SafeFileImage({required this.path});

  @override
  Widget build(BuildContext context) {
    final f = File(path);
    return FutureBuilder<bool>(
      future: f.exists(),
      builder: (_, snap) {
        final ok = snap.data == true;
        if (!ok) {
          return Container(
            color: Colors.white.withOpacity(0.04),
            child: const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white54, size: 40)),
          );
        }
        return Image.file(f, fit: BoxFit.cover, errorBuilder: (_, __, ___) {
          return Container(
            color: Colors.white.withOpacity(0.04),
            child: const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white54, size: 40)),
          );
        });
      },
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                   HELPERS                                  */
/* -------------------------------------------------------------------------- */

String _uid() {
  // compact random id
  final r = Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
}

Future<bool?> _confirm(BuildContext context, {required String title, required String body}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Onayla')),
      ],
    ),
  );
}
