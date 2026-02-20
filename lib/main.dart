import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

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

/* ------------------------------- OUTFIT STORE ------------------------------ */

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = OutfitStore();
  await store.load();

  final weather = WeatherStore();
  // Fire and forget: UI will show loading/error/state.
  weather.refresh();

  runApp(OutfitApp(store: store, weather: weather));
}

/* ----------------------------- DOMAIN MODELS ----------------------------- */
enum LaundryState { ready, dirty, laundry }

LaundryState laundryFromCode(String? code) {
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
}

class ClothingItem {
  final String id;

  /// Stored under app documents: .../outfit_images/<id>.<ext>
  final String imagePath;
  final String? imageName;

  final String category; // TOP/BOTTOM/OUTER/SHOES/ACCESSORY
  final String color; // Black/White/Red...
  final String note;

  final LaundryState laundry; // ready/dirty/laundry
  final DateTime createdAt;

  /// Last time the user marked this item as worn. Used for cooldown.
  final DateTime? lastWornAt;

  /// 1=İnce 2=Orta 3=Kalın (multi-select)
  final List<int> warmths;

  /// casual/sport/smart/formal (multi-select)
  final List<String> occasions;

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
  });

  bool supportsWarmth(int w) => warmths.contains(w);

  bool supportsOccasion(String o) => occasions.contains(o);

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
    );
  }

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
      };

  factory ClothingItem.fromJson(Map<String, dynamic> j) => ClothingItem(
        id: j['id'] as String,
        imagePath: j['imagePath'] as String,
        imageName: j['imageName'] as String?,
        category: j['category'] as String,
        color: j['color'] as String,
        note: (j['note'] as String?) ?? '',
        laundry: laundryFromCode(j['laundry'] as String?),
        createdAt: DateTime.parse(j['createdAt'] as String),
        lastWornAt: (j['lastWornAt'] as String?) == null ? null : DateTime.tryParse(j['lastWornAt'] as String),
        warmths: ((j['warmths'] as List?) ?? const [2]).map((e) => (e as num).toInt()).toList(),
        occasions: ((j['occasions'] as List?) ?? const ['casual']).map((e) => e.toString()).toList(),
      );
}

class OutfitStore extends ChangeNotifier {
  final List<ClothingItem> _items = [];
  List<ClothingItem> get items => List.unmodifiable(_items);

  final List<OutfitLog> _history = [];
  List<OutfitLog> get history => List.unmodifiable(_history);

  Directory? _imagesDir;
  File? _indexFile;
  bool _inited = false;

  bool _logOutfitBusy = false;

  bool get logOutfitBusy => _logOutfitBusy;

  Future<void> _init() async {
    if (_inited) return;
    final docs = await getApplicationDocumentsDirectory();
    _imagesDir = Directory(p.join(docs.path, 'outfit_images'));
    if (!await _imagesDir!.exists()) {
      await _imagesDir!.create(recursive: true);
    }
    _indexFile = File(p.join(docs.path, 'items.json'));
    _inited = true;
  }

  ClothingItem? byId(String id) {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx == -1) return null;
    return _items[idx];
  }

  Future<void> load() async {
    await _init();
    if (!await _indexFile!.exists()) return;
    try {
      final raw = await _indexFile!.readAsString();
      if (raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);

      List<dynamic> itemsList = const [];
      List<dynamic> histList = const [];

      if (decoded is List) {
        itemsList = decoded;
      } else if (decoded is Map) {
        itemsList = (decoded['items'] as List?) ?? const [];
        histList = (decoded['history'] as List?) ?? const [];
      }

      _items
        ..clear()
        ..addAll(itemsList.map((e) => ClothingItem.fromJson((e as Map).cast<String, dynamic>())));

      _history
        ..clear()
        ..addAll(histList.map((e) => OutfitLog.fromJson((e as Map).cast<String, dynamic>())));

      notifyListeners();
    } catch (_) {
      _items.clear();
      _history.clear();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
  await _init();
  final payload = {
    'items': _items.map((e) => e.toJson()).toList(),
    'history': _history.map((e) => e.toJson()).toList(),
  };

  final json = jsonEncode(payload);
  final dst = _indexFile!;
  final tmp = File('${dst.path}.tmp');

  try {
    await tmp.writeAsString(json, flush: true);
    if (await dst.exists()) {
      try {
        await dst.delete();
      } catch (_) {}
    }
    await tmp.rename(dst.path);
  } catch (_) {
    // Fallback: try direct write.
    try {
      await dst.writeAsString(json, flush: true);
    } catch (_) {}
  }
}

  Future<String> savePickedImageToAppDir({
  required XFile picked,
  required String id,
}) async {
  await _init();
  final ext0 = p.extension(picked.path);
  final ext = ext0.isEmpty ? '.jpg' : ext0;
  final dstPath = p.join(_imagesDir!.path, '$id$ext');

  try {
    final src = File(picked.path);
    if (await src.exists()) {
      await src.copy(dstPath);
    } else {
      // Some pickers can return a path that isn't directly readable later.
      final bytes = await picked.readAsBytes();
      await File(dstPath).writeAsBytes(bytes, flush: true);
    }
  } catch (_) {
    final bytes = await picked.readAsBytes();
    await File(dstPath).writeAsBytes(bytes, flush: true);
  }

  return dstPath;
}

  Future<String> replaceImage({
    required String id,
    required XFile picked,
    required String oldImagePath,
  }) async {
    final newPath = await savePickedImageToAppDir(picked: picked, id: id);

    // If extension changed, old path differs -> delete old file.
    if (newPath != oldImagePath) {
      try {
        final old = File(oldImagePath);
        if (await old.exists()) await old.delete();
      } catch (_) {}
    }
    return newPath;
  }

  Future<void> add(ClothingItem item) async {
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

  Future<void> removeById(String id) async {
  final idx = _items.indexWhere((e) => e.id == id);
  if (idx == -1) return;

  final removed = _items.removeAt(idx);

  // Delete image file.
  try {
    final f = File(removed.imagePath);
    if (await f.exists()) await f.delete();
  } catch (_) {}

  // Clean history references (so UI doesn't fill with unknown tiles).
  for (var i = _history.length - 1; i >= 0; i--) {
    final h = _history[i];
    if (!h.itemIds.contains(id)) continue;

    final newIds = h.itemIds.where((x) => x != id).toList();
    if (newIds.isEmpty) {
      _history.removeAt(i);
    } else {
      _history[i] = h.copyWith(itemIds: newIds);
    }
  }

  notifyListeners();
  await _persist();
}

  Future<bool> logOutfit({
  required List<String> itemIds,
  required String event,
  String? weatherBucket,
  double? tempC,
  bool? raining,
}) async {
  // Prevent multi-tap spam: ignore while a previous log is still being processed.
  if (_logOutfitBusy) return false;
  _logOutfitBusy = true;

  bool sameIdSet(List<String> a, List<String> b) {
    final sa = a.toSet();
    final sb = b.toSet();
    return sa.length == sb.length && sa.containsAll(sb);
  }

  try {
    if (itemIds.isEmpty) return false;

    final when = DateTime.now();

    // Stable, de-duplicated ids
    final uniqueIds = itemIds.toSet().toList()..sort();

    // Kombin uniqueness: if it's already in history, don't create a duplicate entry.
    // (User can delete the history entry to allow re-adding.)
    final exists = _history.any((h) => sameIdSet(h.itemIds, uniqueIds));

    // Always update lastWornAt so scoring/cooldown works even if the log already exists.
    for (final id in uniqueIds) {
      final idx = _items.indexWhere((e) => e.id == id);
      if (idx == -1) continue;
      _items[idx] = _items[idx].copyWith(lastWornAt: when);
    }

    if (!exists) {
      _history.insert(
        0,
        OutfitLog(
          wornAt: when,
          itemIds: uniqueIds,
          event: event,
          weatherBucket: weatherBucket,
          tempC: tempC,
          raining: raining,
        ),
      );

      // Keep history bounded.
      if (_history.length > 200) {
        _history.removeRange(200, _history.length);
      }
    }

    notifyListeners();
    await _persist();

    return !exists;
  } finally {
    _logOutfitBusy = false;
  }
}

  Future<void> deleteHistoryAt(int index) async {
    if (index < 0 || index >= _history.length) return;
    _history.removeAt(index);
    notifyListeners();
    await _persist();
  }

Future<void> clearHistory() async {
    _history.clear();
    notifyListeners();
    await _persist();
  }
}

class OutfitLog {
  final DateTime wornAt;
  final List<String> itemIds;
  final String event; // sport/cafe/office/dinner/formal
  final String? weatherBucket; // Cold/Mild/Hot
  final double? tempC;
  final bool? raining;

  const OutfitLog({
    required this.wornAt,
    required this.itemIds,
    required this.event,
    this.weatherBucket,
    this.tempC,
    this.raining,
  });

  OutfitLog copyWith({
    DateTime? wornAt,
    List<String>? itemIds,
    String? event,
    String? weatherBucket,
    double? tempC,
    bool? raining,
  }) {
    return OutfitLog(
      wornAt: wornAt ?? this.wornAt,
      itemIds: itemIds ?? this.itemIds,
      event: event ?? this.event,
      weatherBucket: weatherBucket ?? this.weatherBucket,
      tempC: tempC ?? this.tempC,
      raining: raining ?? this.raining,
    );
  }

  Map<String, dynamic> toJson() => {
        'wornAt': wornAt.toIso8601String(),
        'itemIds': itemIds,
        'event': event,
        'weatherBucket': weatherBucket,
        'tempC': tempC,
        'raining': raining,
      };

  factory OutfitLog.fromJson(Map<String, dynamic> j) => OutfitLog(
        wornAt: DateTime.parse(j['wornAt'] as String),
        itemIds: ((j['itemIds'] as List?) ?? const []).map((e) => e.toString()).toList(),
        event: (j['event'] as String?) ?? 'cafe',
        weatherBucket: j['weatherBucket'] as String?,
        tempC: (j['tempC'] as num?)?.toDouble(),
        raining: j['raining'] as bool?,
      );
}

/* ------------------------------- WEATHER STORE ------------------------------ */

class WeatherStore extends ChangeNotifier {
  bool loading = false;
  String? error;

  WeatherNow? now;
  List<WeatherHour> hours = const [];

  /// Derived:
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

      bucket = _bucketFromTemp(n.temperatureC, windKmh: n.windKmh);
      desiredWarmth = _desiredWarmthFromBucket(bucket);

      loading = false;
      notifyListeners();
    } catch (e) {
      loading = false;
      error = e.toString();
      notifyListeners();
    }
  }

  int _desiredWarmthFromBucket(String b) {
    switch (b) {
      case 'Cold':
        return 3;
      case 'Hot':
        return 1;
      default:
        return 2;
    }
  }

  String _bucketFromTemp(double c, {required double windKmh}) {
    // Simple + a small wind adjustment.
    var b = c <= 12 ? 'Cold' : (c <= 20 ? 'Mild' : 'Hot');
    if (windKmh >= 28 && b == 'Mild') b = 'Cold';
    if (windKmh >= 38 && b == 'Hot') b = 'Mild';
    return b;
  }

  Future<Position> _safeGetPosition() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw Exception('Konum servisi kapalı');
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      throw Exception('Konum izni reddedildi');
    }
    if (perm == LocationPermission.deniedForever) {
      throw Exception('Konum izni kalıcı reddedildi');
    }

    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return last;

    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low, // faster
      timeLimit: const Duration(seconds: 25),
    );
  }

  Future<(WeatherNow, List<WeatherHour>)> _fetchOpenMeteo(double lat, double lon) async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat'
      '&longitude=$lon'
      '&current=temperature_2m,precipitation,wind_speed_10m,weather_code'
      '&hourly=temperature_2m,precipitation_probability,precipitation,wind_speed_10m,weather_code'
      '&forecast_days=1'
      '&timezone=auto',
    );

    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Hava servisi hata verdi (${res.statusCode})');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;

    final cur = (data['current'] as Map?)?.cast<String, dynamic>();
    if (cur == null) throw Exception('Hava verisi alınamadı');

    final now = WeatherNow(
      time: DateTime.parse(cur['time'] as String),
      temperatureC: (cur['temperature_2m'] as num).toDouble(),
      precipitationMm: (cur['precipitation'] as num).toDouble(),
      windKmh: (cur['wind_speed_10m'] as num).toDouble(),
      weatherCode: (cur['weather_code'] as num).toInt(),
    );

    final hourly = (data['hourly'] as Map?)?.cast<String, dynamic>();
    if (hourly == null) return (now, const <WeatherHour>[]);

    final times = (hourly['time'] as List).map((e) => DateTime.parse(e as String)).toList();
    final temps = (hourly['temperature_2m'] as List).map((e) => (e as num).toDouble()).toList();
    final pprob = (hourly['precipitation_probability'] as List).map((e) => (e as num?)?.toInt() ?? 0).toList();
    final prec = (hourly['precipitation'] as List).map((e) => (e as num).toDouble()).toList();
    final wind = (hourly['wind_speed_10m'] as List).map((e) => (e as num).toDouble()).toList();
    final wcode = (hourly['weather_code'] as List).map((e) => (e as num).toInt()).toList();

    final hrs = <WeatherHour>[];
    final n = [times.length, temps.length, pprob.length, prec.length, wind.length, wcode.length].reduce((a, b) => a < b ? a : b);

    for (var i = 0; i < n; i++) {
      hrs.add(
        WeatherHour(
          time: times[i],
          temperatureC: temps[i],
          precipitationProb: pprob[i],
          precipitationMm: prec[i],
          windKmh: wind[i],
          weatherCode: wcode[i],
        ),
      );
    }

    return (now, hrs);
  }
}

/* --------------------------------- UI APP --------------------------------- */

class OutfitApp extends StatelessWidget {
  final OutfitStore store;
  final WeatherStore weather;

  const OutfitApp({super.key, required this.store, required this.weather});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Outfit Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF070A1C),
        fontFamily: null,
        useMaterial3: true,
      ),
      home: HomePage(store: store, weather: weather),
    );
  }
}

/* -------------------------------- HOME PAGE ------------------------------- */

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
                      _QuickPill(
                        text: 'Kafe',
                        icon: Icons.local_cafe_rounded,
                        onTap: () => _openPlanner(context, event: 'cafe'),
                      ),
                      _QuickPill(
                        text: 'Spor',
                        icon: Icons.fitness_center_rounded,
                        onTap: () => _openPlanner(context, event: 'sport'),
                      ),
                      _QuickPill(
                        text: 'Ofis',
                        icon: Icons.business_center_rounded,
                        onTap: () => _openPlanner(context, event: 'office'),
                      ),
                      _QuickPill(
                        text: 'Akşam',
                        icon: Icons.restaurant_rounded,
                        onTap: () => _openPlanner(context, event: 'dinner'),
                      ),
                      _QuickPill(
                        text: 'Formal',
                        icon: Icons.local_fire_department_rounded,
                        onTap: () => _openPlanner(context, event: 'formal'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
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
                                  MaterialPageRoute(builder: (_) => AddClothingPage(store: store)),
                                );
                                if (added == true && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Eklendi.')),
                                  );
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
                              onTap: () => _openPlanner(context),
                            ),
                            const Spacer(),
                            Text(
                              'Not: Kalıcılık aktif. Force stop / restart sonrası da dolap durur.',
                              style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
                            ),
                          ],
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

  void _openPlanner(BuildContext context, {String? event}) {
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

/* ------------------------------- ADD CLOTHING ------------------------------ */

class AddClothingPage extends StatefulWidget {
  final OutfitStore store;
  const AddClothingPage({super.key, required this.store});

  @override
  State<AddClothingPage> createState() => _AddClothingPageState();
}

class _AddClothingPageState extends State<AddClothingPage> {
  final _picker = ImagePicker();

  XFile? _pickedFile;
  Uint8List? _pickedBytes;
  String? _pickedName;

  String _category = 'TOP';
  String _color = 'Black';

  final Set<int> _warmths = {2};
  final Set<String> _occasions = {'casual'};

  LaundryState _laundry = LaundryState.ready;

  final _note = TextEditingController();

  bool get _isAccessory => _category == 'ACCESSORY';

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1440,
      );
      if (file == null) return;

      final bytes = await file.readAsBytes();

      setState(() {
        _pickedFile = file;
        _pickedBytes = bytes;
        _pickedName = file.name;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Foto seçme başarısız: $e')),
      );
    }
  }

  Future<void> _save() async {
    if (_pickedFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Önce foto seç.')),
      );
      return;
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final imagePath = await widget.store.savePickedImageToAppDir(picked: _pickedFile!, id: id);

    final warmths = _isAccessory ? <int>[1, 2, 3] : _warmths.toList()..sort();
    final occasions = _occasions.isEmpty ? <String>['casual'] : _occasions.toList()..sort();

    final item = ClothingItem(
      id: id,
      imagePath: imagePath,
      imageName: _pickedName,
      category: _category,
      color: _color,
      note: _note.text.trim(),
      laundry: _laundry,
      createdAt: DateTime.now(),
      warmths: warmths.isEmpty ? const [2] : warmths,
      occasions: occasions,
    );

    await widget.store.add(item);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kıyafet Ekle'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        children: [
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_pickedBytes != null)
                            Image.memory(_pickedBytes!, fit: BoxFit.cover)
                          else
                            Container(
                              color: Colors.white.withOpacity(0.06),
                              child: const Center(
                                child: Icon(Icons.image_rounded, size: 60, color: Color(0xFF6F7AA8)),
                              ),
                            ),
                          Positioned(
                            right: 10,
                            bottom: 10,
                            child: ElevatedButton.icon(
                              onPressed: _pickImage,
                              icon: const Icon(Icons.photo_library_rounded),
                              label: const Text('Foto Seç'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Kategori'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kCategories.map((c) {
                      final selected = _category == c.code;
                      return _SelectChip(
                        label: c.label,
                        icon: c.icon,
                        selected: selected,
                        onTap: () => setState(() => _category = c.code),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Renk'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kColors.map((c) {
                      final selected = _color == c;
                      return _SelectChip(
                        label: c,
                        icon: Icons.palette_rounded,
                        selected: selected,
                        onTap: () => setState(() => _color = c),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Durum'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _SelectChip(
                        label: 'Temiz',
                        icon: Icons.check_circle_rounded,
                        selected: _laundry == LaundryState.ready,
                        onTap: () => setState(() => _laundry = LaundryState.ready),
                      ),
                      _SelectChip(
                        label: 'Kirli',
                        icon: Icons.warning_rounded,
                        selected: _laundry == LaundryState.dirty,
                        onTap: () => setState(() => _laundry = LaundryState.dirty),
                      ),
                      _SelectChip(
                        label: 'Çamaşırda',
                        icon: Icons.local_laundry_service_rounded,
                        selected: _laundry == LaundryState.laundry,
                        onTap: () => setState(() => _laundry = LaundryState.laundry),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),
                  if (!_isAccessory) ...[
                    const _SectionTitle('Kalınlık'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: kWarmths.map((w) {
                        final selected = _warmths.contains(w.value);
                        return _SelectChip(
                          label: w.label,
                          icon: w.icon,
                          selected: selected,
                          onTap: () {
                            setState(() {
                              if (selected) {
                                if (_warmths.length > 1) _warmths.remove(w.value);
                              } else {
                                _warmths.add(w.value);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                  ],
                  const _SectionTitle('Ortam'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kOccasions.map((o) {
                      final selected = _occasions.contains(o.code);
                      return _SelectChip(
                        label: o.label,
                        icon: o.icon,
                        selected: selected,
                        onTap: () {
                          setState(() {
                            if (selected) {
                              if (_occasions.length > 1) _occasions.remove(o.code);
                            } else {
                              _occasions.add(o.code);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Not'),
                  const SizedBox(height: 10),
                  _TextField(controller: _note, hint: 'Örn: Yıkamaya gidecek / özel gün...'),
                  const SizedBox(height: 14),
                  _PrimaryButton(text: 'Kaydet', icon: Icons.check_rounded, onTap: _save),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* --------------------------------- CLOSET --------------------------------- */

class ClosetPage extends StatefulWidget {
  final OutfitStore store;
  const ClosetPage({super.key, required this.store});

  @override
  State<ClosetPage> createState() => _ClosetPageState();
}

class _ClosetPageState extends State<ClosetPage> {
  String _query = '';
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: _query);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _category = 'ALL';
  String _color = 'ALL';
  String _occasion = 'ALL';
  String _warmth = 'ALL';
  String _laundry = 'ALL';

  String _warmthLabel(String v) {
    switch (v) {
      case 'ALL':
        return 'Hepsi';
      case '1':
        return 'İnce';
      case '2':
        return 'Orta';
      case '3':
        return 'Kalın';
      default:
        return v;
    }
  }


  String _laundryLabel(String v) {
    switch (v) {
      case 'ALL':
        return 'Hepsi';
      case 'ready':
        return 'Temiz';
      case 'dirty':
        return 'Kirli';
      case 'laundry':
        return 'Çamaşırda';
      default:
        return v;
    }
  }

  String _occasionLabel(String v) {
    if (v == 'ALL') return 'Hepsi';
    final found = kOccasions.where((e) => e.code == v).toList();
    return found.isEmpty ? v : found.first.label;
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        final items = store.items.where((it) {
          if (_category != 'ALL' && it.category != _category) return false;
          if (_color != 'ALL' && it.color != _color) return false;
          if (_warmth != 'ALL' && !it.supportsWarmth(int.parse(_warmth))) return false;
          if (_occasion != 'ALL' && !it.supportsOccasion(_occasion)) return false;
          if (_laundry != 'ALL' && it.laundry.code != _laundry) return false;

          final q = _query.trim().toLowerCase();
          if (q.isEmpty) return true;

          final blob = [
            it.category,
            it.color,
            it.note,
            it.imageName ?? '',
            it.warmths.join(','),
            it.occasions.join(','),
            it.laundry.label,
          ].join(' ').toLowerCase();

          return blob.contains(q);
        }).toList();

        return Scaffold(
          appBar: AppBar(title: const Text('Dolabım')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _TextField(
                controller: _searchCtrl,
                hint: 'Ara (renk, not, ortam...)',
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _FilterChipRow(
                      label: 'Kategori',
                      value: _category,
                      values: ['ALL', ...kCategories.map((e) => e.code)],
                      display: (v) => v == 'ALL'
                          ? 'Hepsi'
                          : kCategories.firstWhere((e) => e.code == v, orElse: () => kCategories.first).label,
                      onPick: (v) => setState(() => _category = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _FilterChipRow(
                      label: 'Renk',
                      value: _color,
                      values: ['ALL', ...kColors],
                      display: (v) => v == 'ALL' ? 'Hepsi' : v,
                      onPick: (v) => setState(() => _color = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _FilterChipRow(
                      label: 'Ortam',
                      value: _occasion,
                      values: ['ALL', ...kOccasions.map((e) => e.code)],
                      display: _occasionLabel,
                      onPick: (v) => setState(() => _occasion = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _FilterChipRow(
                      label: 'Kalınlık',
                      value: _warmth,
                      values: const ['ALL', '1', '2', '3'],
                      display: _warmthLabel,
                      onPick: (v) => setState(() => _warmth = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _FilterChipRow(
                label: 'Durum',
                value: _laundry,
                values: const ['ALL', 'ready', 'dirty', 'laundry'],
                display: _laundryLabel,
                onPick: (v) => setState(() => _laundry = v),
              ),
              const SizedBox(height: 14),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: Center(
                    child: Text(
                      'Hiç kıyafet yok.',
                      style: TextStyle(color: Colors.white.withOpacity(0.6)),
                    ),
                  ),
                )
              else
                GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final it = items[i];
                    return _ClosetCard(
                      item: it,
                      onTap: () async {
                        final changed = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(builder: (_) => ClothingDetailPage(store: store, item: it)),
                        );
                        if (changed == true && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Güncellendi.')),
                          );
                        }
                      },
                      onLongPress: () async {
                        await store.removeById(it.id);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Silindi.')),
                        );
                      },
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/* ------------------------------ CLOTHING DETAIL ---------------------------- */

class ClothingDetailPage extends StatelessWidget {
  final OutfitStore store;
  final ClothingItem item;

  const ClothingDetailPage({super.key, required this.store, required this.item});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        // item might be updated; re-fetch it
        final current = store.items.firstWhere((e) => e.id == item.id, orElse: () => item);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Detay'),
            actions: [
              IconButton(
                tooltip: 'Düzenle',
                onPressed: () async {
                  final updated = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => EditClothingPage(store: store, item: current)),
                  );
                  if (updated == true && context.mounted) Navigator.pop(context, true);
                },
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
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: AspectRatio(
                          aspectRatio: 1.2,
                          child: _SafeFileImage(path: current.imagePath),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _Badge(text: current.category, icon: Icons.checkroom_rounded),
                          _Badge(text: current.color, icon: Icons.palette_rounded),
                          _Badge(text: current.laundry.label, icon: current.laundry.icon),
                          _Badge(text: current.warmths.map(_warmthName).join(', '), icon: Icons.thermostat_rounded),
                          _Badge(text: current.occasions.map(_occasionName).join(', '), icon: Icons.event_rounded),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (current.note.trim().isNotEmpty) ...[
                        const _SectionTitle('Not'),
                        const SizedBox(height: 8),
                        Text(current.note, style: TextStyle(color: Colors.white.withOpacity(0.85))),
                        const SizedBox(height: 12),
                      ],
                      _PrimaryButton(
                        text: 'Sil',
                        icon: Icons.delete_rounded,
                        onTap: () async {
                          await store.removeById(current.id);
                          if (context.mounted) Navigator.pop(context, true);
                        },
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

  String _warmthName(int w) {
    switch (w) {
      case 1:
        return 'İnce';
      case 2:
        return 'Orta';
      case 3:
        return 'Kalın';
      default:
        return '$w';
    }
  }

  String _occasionName(String o) {
    final found = kOccasions.where((e) => e.code == o).toList();
    return found.isEmpty ? o : found.first.label;
  }
}

/* ------------------------------- EDIT CLOTHING ----------------------------- */


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
      case 'cafe':
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
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Geçmişi temizle?'),
                        content: const Text('Tüm kombin geçmişi silinecek.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
                          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sil')),
                        ],
                      ),
                    );
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
                    final dt = log.wornAt;
                    final date = '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
                    final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

                    final meta = <String>[
                      _eventLabel(log.event),
                      if (log.tempC != null) '${log.tempC!.toStringAsFixed(0)}°',
                      if (log.weatherBucket != null) log.weatherBucket!,
                      if (log.raining == true) 'Yağış',
                    ].join(' • ');

                    final items = log.itemIds.map(store.byId).toList();

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
                                    '$date  $time',
                                    style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
                                  ),
                                ),
                                const Icon(Icons.history_rounded, color: Color(0xFF00E5FF)),
                                const SizedBox(width: 6),
                                IconButton(
                                  tooltip: 'Sil',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (_) => AlertDialog(
                                        title: const Text('Kombini sil?'),
                                        content: const Text('Bu kayıt geçmişten kaldırılacak.'),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(context, false),
                                            child: const Text('Vazgeç'),
                                          ),
                                          TextButton(
                                            onPressed: () => Navigator.pop(context, true),
                                            child: const Text('Sil'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      await store.deleteHistoryAt(i);
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Kombin silindi')),
                                      );
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
                                for (final it in items)
                                  _HistorySlot(item: it),
                              ],
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

class _HistorySlot extends StatelessWidget {
  final ClothingItem? item;
  const _HistorySlot({required this.item});

  @override
  Widget build(BuildContext context) {
    final it = item;
    return Container(
      width: 90,
      height: 90,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: it == null
            ? Center(child: Icon(Icons.help_outline_rounded, color: Colors.white.withOpacity(0.55)))
            : Stack(
                fit: StackFit.expand,
                children: [
                  _SafeFileImage(path: it.imagePath),
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.45)),
                      child: Text(
                        it.category,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class EditClothingPage extends StatefulWidget {
  final OutfitStore store;
  final ClothingItem item;

  const EditClothingPage({super.key, required this.store, required this.item});

  @override
  State<EditClothingPage> createState() => _EditClothingPageState();
}

class _EditClothingPageState extends State<EditClothingPage> {
  final _picker = ImagePicker();

  String _category = 'TOP';
  String _color = 'Black';

  final Set<int> _warmths = {2};
  final Set<String> _occasions = {'casual'};

  LaundryState _laundry = LaundryState.ready;

  final _note = TextEditingController();

  XFile? _newImage;
  Uint8List? _newPreview;

  bool get _isAccessory => _category == 'ACCESSORY';

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    _category = it.category;
    _color = it.color;
    _laundry = it.laundry;
    _warmths
      ..clear()
      ..addAll(it.warmths.isEmpty ? const [2] : it.warmths);
    _occasions
      ..clear()
      ..addAll(it.occasions.isEmpty ? const ['casual'] : it.occasions);
    _note.text = it.note;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickNewImage() async {
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1440,
      );
      if (file == null) return;

      final bytes = await file.readAsBytes();
      setState(() {
        _newImage = file;
        _newPreview = bytes;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Foto seçme başarısız: $e')),
      );
    }
  }

  Future<void> _save() async {
    String imagePath = widget.item.imagePath;

    if (_newImage != null) {
      imagePath = await widget.store.replaceImage(
        id: widget.item.id,
        picked: _newImage!,
        oldImagePath: widget.item.imagePath,
      );
    }

    final warmths = _isAccessory ? <int>[1, 2, 3] : _warmths.toList()..sort();
    final occasions = _occasions.isEmpty ? <String>['casual'] : _occasions.toList()..sort();

    final updated = widget.item.copyWith(
      imagePath: imagePath,
      category: _category,
      color: _color,
      note: _note.text.trim(),
      laundry: _laundry,
      warmths: warmths.isEmpty ? const [2] : warmths,
      occasions: occasions,
    );

    await widget.store.updateItem(updated);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Düzenle'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        children: [
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_newPreview != null)
                            Image.memory(_newPreview!, fit: BoxFit.cover)
                          else
                            _SafeFileImage(path: it.imagePath),
                          Positioned(
                            right: 10,
                            bottom: 10,
                            child: ElevatedButton.icon(
                              onPressed: _pickNewImage,
                              icon: const Icon(Icons.photo_library_rounded),
                              label: const Text('Foto Değiştir'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Kategori'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kCategories.map((c) {
                      final selected = _category == c.code;
                      return _SelectChip(
                        label: c.label,
                        icon: c.icon,
                        selected: selected,
                        onTap: () => setState(() => _category = c.code),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Renk'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kColors.map((c) {
                      final selected = _color == c;
                      return _SelectChip(
                        label: c,
                        icon: Icons.palette_rounded,
                        selected: selected,
                        onTap: () => setState(() => _color = c),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Durum'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _SelectChip(
                        label: 'Temiz',
                        icon: Icons.check_circle_rounded,
                        selected: _laundry == LaundryState.ready,
                        onTap: () => setState(() => _laundry = LaundryState.ready),
                      ),
                      _SelectChip(
                        label: 'Kirli',
                        icon: Icons.warning_rounded,
                        selected: _laundry == LaundryState.dirty,
                        onTap: () => setState(() => _laundry = LaundryState.dirty),
                      ),
                      _SelectChip(
                        label: 'Çamaşırda',
                        icon: Icons.local_laundry_service_rounded,
                        selected: _laundry == LaundryState.laundry,
                        onTap: () => setState(() => _laundry = LaundryState.laundry),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (!_isAccessory) ...[
                    const _SectionTitle('Kalınlık'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: kWarmths.map((w) {
                        final selected = _warmths.contains(w.value);
                        return _SelectChip(
                          label: w.label,
                          icon: w.icon,
                          selected: selected,
                          onTap: () {
                            setState(() {
                              if (selected) {
                                if (_warmths.length > 1) _warmths.remove(w.value);
                              } else {
                                _warmths.add(w.value);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                  ],
                  const _SectionTitle('Ortam'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kOccasions.map((o) {
                      final selected = _occasions.contains(o.code);
                      return _SelectChip(
                        label: o.label,
                        icon: o.icon,
                        selected: selected,
                        onTap: () {
                          setState(() {
                            if (selected) {
                              if (_occasions.length > 1) _occasions.remove(o.code);
                            } else {
                              _occasions.add(o.code);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const _SectionTitle('Not'),
                  const SizedBox(height: 10),
                  _TextField(controller: _note, hint: 'Örn: Yıkamaya gidecek / özel gün...'),
                  const SizedBox(height: 14),
                  _PrimaryButton(text: 'Kaydet', icon: Icons.check_rounded, onTap: _save),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------ OUTFIT PLANNER ----------------------------- */

class OutfitPlannerPage extends StatefulWidget {
  final OutfitStore store;
  final WeatherStore weather;
  final String? presetEvent;

  const OutfitPlannerPage({super.key, required this.store, required this.weather, this.presetEvent});

  @override
  State<OutfitPlannerPage> createState() => _OutfitPlannerPageState();
}

class _OutfitPlannerPageState extends State<OutfitPlannerPage> {
  late String _event; // sport/cafe/office/dinner/formal

  @override
  void initState() {
    super.initState();
    _event = widget.presetEvent ?? 'cafe';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.store, widget.weather]),
      builder: (_, __) {
        final wx = widget.weather;
        final items = widget.store.items;

        final desiredOccasion = _desiredOccasionFromEvent(_event);
        final bucket = wx.now == null ? 'Mild' : wx.bucket;
        final desiredWarmth = wx.now == null ? 2 : wx.desiredWarmth;

        final suggestions = _generateTop3(
          items: items,
          weatherBucket: bucket,
          desiredWarmth: desiredWarmth,
          desiredOccasion: desiredOccasion,
          rainingNow: (wx.now?.precipitationMm ?? 0) > 0.2,
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
                tooltip: 'Geçmiş',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => OutfitHistoryPage(store: widget.store)),
                ),
                icon: const Icon(Icons.history_rounded),
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
                      const _SectionTitle('Ortam'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _SelectChip(
                            label: 'Spor',
                            icon: Icons.fitness_center_rounded,
                            selected: _event == 'sport',
                            onTap: () => setState(() => _event = 'sport'),
                          ),
                          _SelectChip(
                            label: 'Kafe',
                            icon: Icons.local_cafe_rounded,
                            selected: _event == 'cafe',
                            onTap: () => setState(() => _event = 'cafe'),
                          ),
                          _SelectChip(
                            label: 'Ofis',
                            icon: Icons.business_center_rounded,
                            selected: _event == 'office',
                            onTap: () => setState(() => _event = 'office'),
                          ),
                          _SelectChip(
                            label: 'Akşam',
                            icon: Icons.restaurant_rounded,
                            selected: _event == 'dinner',
                            onTap: () => setState(() => _event = 'dinner'),
                          ),
                          _SelectChip(
                            label: 'Formal',
                            icon: Icons.star_rounded,
                            selected: _event == 'formal',
                            onTap: () => setState(() => _event = 'formal'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Hedef kalınlık: ${_warmthName(desiredWarmth)}  •  Hava: $bucket',
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
                      'Kombin üretemedim. En az 1 TOP ve 1 BOTTOM lazım.',
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

  String _desiredOccasionFromEvent(String e) {
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

  String _warmthName(int w) {
    switch (w) {
      case 1:
        return 'İnce';
      case 2:
        return 'Orta';
      case 3:
        return 'Kalın';
      default:
        return '$w';
    }
  }

  List<OutfitSuggestion> _generateTop3({
    required List<ClothingItem> items,
    required String weatherBucket,
    required int desiredWarmth,
    required String desiredOccasion,
    required bool rainingNow,
  }) {
    if (items.isEmpty) return const [];

    // Only suggest clean clothes (Temiz). Strict by occasion; fallback if empty.
    var pool = items
        .where((it) => it.laundry == LaundryState.ready && it.supportsOccasion(desiredOccasion))
        .toList();
    if (pool.isEmpty) {
      pool = items.where((it) => it.laundry == LaundryState.ready).toList();
    }
    if (pool.isEmpty) return const [];

    final tops = pool.where((e) => e.category == 'TOP').toList();
    final bottoms = pool.where((e) => e.category == 'BOTTOM').toList();
    final outers = pool.where((e) => e.category == 'OUTER').toList();
    final shoes = pool.where((e) => e.category == 'SHOES').toList();
    final accs = pool.where((e) => e.category == 'ACCESSORY').toList();

    if (tops.isEmpty || bottoms.isEmpty) return const [];

    // Rank candidates by item score.
    int compareScore(ClothingItem a, ClothingItem b) =>
        _itemScore(b, desiredWarmth, desiredOccasion, weatherBucket, rainingNow)
            .compareTo(_itemScore(a, desiredWarmth, desiredOccasion, weatherBucket, rainingNow));

    tops.sort(compareScore);
    bottoms.sort(compareScore);
    outers.sort(compareScore);
    shoes.sort(compareScore);
    accs.sort(compareScore);

    final topN = (List<ClothingItem> xs, int n) => xs.take(n).toList();
    final topTops = topN(tops, 6);
    final topBottoms = topN(bottoms, 6);
    final topShoes = topN(shoes, 4);
    final topAcc = topN(accs, 3);
    final topOuter = topN(outers, 4);

    final allowOuter = weatherBucket != 'Hot';
    final wantOuter = weatherBucket == 'Cold' || rainingNow;

    final suggestions = <OutfitSuggestion>[];

    for (final t in topTops) {
      for (final b in topBottoms) {
        // Choose best shoe and accessory independently.
        final sh = topShoes.isEmpty ? null : topShoes.first;
        final ac = topAcc.isEmpty ? null : topAcc.first;

        ClothingItem? ot;
        if (allowOuter && topOuter.isNotEmpty) {
          // Only include outer if it helps (cold/rain) or if its score is high.
          ot = wantOuter ? topOuter.first : null;
        }

        final score = _outfitScore(
          top: t,
          bottom: b,
          outer: ot,
          shoes: sh,
          accessory: ac,
          desiredWarmth: desiredWarmth,
          desiredOccasion: desiredOccasion,
          weatherBucket: weatherBucket,
          rainingNow: rainingNow,
        );

        suggestions.add(
          OutfitSuggestion(
            top: t,
            bottom: b,
            outer: ot,
            shoes: sh,
            accessory: ac,
            score: score,
          ),
        );
      }
    }

    suggestions.sort((a, b) => b.score.compareTo(a.score));

    // Pick top 3 distinct combos.
    final picked = <OutfitSuggestion>[];
    final usedKeys = <String>{};

    for (final s in suggestions) {
      final key = [
        s.top.id,
        s.bottom.id,
        s.outer?.id ?? '',
        s.shoes?.id ?? '',
        s.accessory?.id ?? '',
      ].join('|');
      if (usedKeys.add(key)) {
        picked.add(s);
        if (picked.length == 3) break;
      }
    }

    return picked;
  }

  double _itemScore(
    ClothingItem it,
    int desiredWarmth,
    String desiredOccasion,
    String weatherBucket,
    bool rainingNow,
  ) {
    double score = 0;

    // Warmth match: best among selected warmths.
    final diffs = it.warmths.isEmpty ? [100] : it.warmths.map((w) => (w - desiredWarmth).abs()).toList();
    final d = diffs.reduce((a, b) => a < b ? a : b);
    if (d == 0) score += 10;
    if (d == 1) score += 3;
    if (d >= 2) score -= 6;

    // Occasion match
    if (it.supportsOccasion(desiredOccasion)) score += 8;

    // Cooldown: recently worn items are penalized so suggestions rotate.
    final lw = it.lastWornAt;
    if (lw != null) {
      final hours = DateTime.now().difference(lw).inHours;
      if (hours < 24) score -= 25;
      else if (hours < 48) score -= 14;
      else if (hours < 72) score -= 8;
      else if (hours < 168) score -= 3;
    }

    // Outer behavior
    if (it.category == 'OUTER') {
      if (weatherBucket == 'Cold' || rainingNow) score += 6;
      if (weatherBucket == 'Hot') score -= 50;
    }

    // Neutral colors a bit flexible
    if (it.color == 'Black' || it.color == 'White' || it.color == 'Gray' || it.color == 'Beige') score += 1.5;

    return score;
  }

  double _outfitScore({
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
    double s = 0;
    s += _itemScore(top, desiredWarmth, desiredOccasion, weatherBucket, rainingNow);
    s += _itemScore(bottom, desiredWarmth, desiredOccasion, weatherBucket, rainingNow);

    if (shoes != null) s += _itemScore(shoes, desiredWarmth, desiredOccasion, weatherBucket, rainingNow) * 0.7;
    if (accessory != null) s += _itemScore(accessory, desiredWarmth, desiredOccasion, weatherBucket, rainingNow) * 0.4;

    if (outer != null) {
      if (weatherBucket == 'Hot') return -999; // never
      s += _itemScore(outer, desiredWarmth, desiredOccasion, weatherBucket, rainingNow) * 0.8;
    } else {
      // Cold/rain without outer = slight penalty
      if (weatherBucket == 'Cold' || rainingNow) s -= 6;
    }

    // Color pairing (very simple)
    if (top.color == bottom.color) s += 3;
    if (_isNeutral(top.color) || _isNeutral(bottom.color)) s += 2;

    return s;
  }

  bool _isNeutral(String c) => c == 'Black' || c == 'White' || c == 'Gray' || c == 'Beige';
}

class OutfitSuggestion {
  final ClothingItem top;
  final ClothingItem bottom;
  final ClothingItem? outer;
  final ClothingItem? shoes;
  final ClothingItem? accessory;
  final double score;

  const OutfitSuggestion({
    required this.top,
    required this.bottom,
    required this.outer,
    required this.shoes,
    required this.accessory,
    required this.score,
  });
}

/* ------------------------------- WEATHER UI -------------------------------- */

class _WeatherInlineCard extends StatelessWidget {
  final WeatherStore weather;

  const _WeatherInlineCard({required this.weather});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Hava Durumu', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
                ),
                TextButton.icon(
                  onPressed: () => weather.refresh(),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Yenile'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (weather.loading) ...[
              const Text('Yükleniyor...', style: TextStyle(color: Color(0xFFA9B3D6))),
            ] else if (weather.error != null) ...[
              Text(
                'Hata: ${weather.error}',
                style: const TextStyle(color: Color(0xFFFFB4B4)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  OutlinedButton(
                    onPressed: () => Geolocator.openLocationSettings(),
                    child: const Text('Konum Ayarları'),
                  ),
                  OutlinedButton(
                    onPressed: () => Geolocator.openAppSettings(),
                    child: const Text('Uygulama Ayarları'),
                  ),
                ],
              ),
            ] else if (weather.now != null) ...[
              _NowRow(now: weather.now!, bucket: weather.bucket),
              const SizedBox(height: 10),
              SizedBox(
                height: 86,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: (weather.hours.length >= 12) ? 12 : weather.hours.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => _HourMini(hour: weather.hours[i]),
                ),
              ),
            ] else ...[
              const Text('Hava verisi yok.', style: TextStyle(color: Color(0xFFA9B3D6))),
            ],
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
        final maxH = MediaQuery.of(context).size.height * 0.85;

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                children: [
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.20),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Hava Detayı', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
                      ),
                      TextButton.icon(
                        onPressed: () => weather.refresh(),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Yenile'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        if (weather.loading)
                          const Padding(
                            padding: EdgeInsets.all(10),
                            child: Text('Yükleniyor...', style: TextStyle(color: Color(0xFFA9B3D6))),
                          )
                        else if (weather.error != null)
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text('Hata: ${weather.error}', style: const TextStyle(color: Color(0xFFFFB4B4))),
                          )
                        else if (weather.now != null) ...[
                          _GlassCard(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: _NowRow(now: weather.now!, bucket: weather.bucket),
                            ),
                          ),
                          const SizedBox(height: 12),
                          _GlassCard(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const _SectionTitle('Saatlik Tahmin'),
                                  const SizedBox(height: 10),
                                  for (final h in weather.hours.take(24)) ...[
                                    _HourRow(hour: h),
                                    Divider(color: Colors.white.withOpacity(0.10)),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ] else
                          const Padding(
                            padding: EdgeInsets.all(10),
                            child: Text('Hava verisi yok.', style: TextStyle(color: Color(0xFFA9B3D6))),
                          ),
                      ],
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
}

class _NowRow extends StatelessWidget {
  final WeatherNow now;
  final String bucket;
  const _NowRow({required this.now, required this.bucket});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WxIcon(code: now.weatherCode, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${now.temperatureC.toStringAsFixed(0)}°C • $bucket',
                style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF), fontSize: 16),
              ),
              const SizedBox(height: 2),
              Text(
                '${_wxLabel(now.weatherCode)} • Yağış ${now.precipitationMm.toStringAsFixed(1)}mm • Rüzgar ${now.windKmh.toStringAsFixed(0)} km/h',
                style: TextStyle(color: Colors.white.withOpacity(0.70), fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HourMini extends StatelessWidget {
  final WeatherHour hour;
  const _HourMini({required this.hour});

  @override
  Widget build(BuildContext context) {
    final t = TimeOfDay.fromDateTime(hour.time);
    return Container(
      width: 92,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
              style: TextStyle(color: Colors.white.withOpacity(0.70), fontSize: 11)),
          const SizedBox(height: 6),
          _WxIcon(code: hour.weatherCode, size: 22),
          const SizedBox(height: 6),
          Text('${hour.temperatureC.toStringAsFixed(0)}°', style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _HourRow extends StatelessWidget {
  final WeatherHour hour;
  const _HourRow({required this.hour});

  @override
  Widget build(BuildContext context) {
    final t = TimeOfDay.fromDateTime(hour.time);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text('${t.hour.toString().padLeft(2, '0')}:00',
                style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12)),
          ),
          _WxIcon(code: hour.weatherCode, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${hour.temperatureC.toStringAsFixed(0)}°C • Yağış %${hour.precipitationProb} • ${hour.windKmh.toStringAsFixed(0)} km/h',
              style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _WxIcon extends StatelessWidget {
  final int code;
  final double size;
  const _WxIcon({required this.code, required this.size});

  @override
  Widget build(BuildContext context) {
    final icon = _wxIconData(code);
    return Icon(icon, size: size, color: const Color(0xFF00E5FF));
  }
}

IconData _wxIconData(int code) {
  // Simplified mapping
  if (code == 0) return Icons.wb_sunny_rounded;
  if (code == 1 || code == 2) return Icons.wb_cloudy_rounded;
  if (code == 3) return Icons.cloud_rounded;
  if (code == 45 || code == 48) return Icons.blur_on_rounded;
  if ([51, 53, 55, 56, 57].contains(code)) return Icons.grain_rounded;
  if ([61, 63, 65, 66, 67].contains(code)) return Icons.umbrella_rounded;
  if ([71, 73, 75, 77].contains(code)) return Icons.ac_unit_rounded;
  if ([80, 81, 82].contains(code)) return Icons.umbrella_rounded;
  if ([95, 96, 99].contains(code)) return Icons.thunderstorm_rounded;
  return Icons.cloud_rounded;
}

String _wxLabel(int code) {
  if (code == 0) return 'Açık';
  if (code == 1) return 'Az bulutlu';
  if (code == 2) return 'Parçalı bulutlu';
  if (code == 3) return 'Kapalı';
  if (code == 45 || code == 48) return 'Sis';
  if ([51, 53, 55].contains(code)) return 'Çiseleme';
  if ([61, 63, 65].contains(code)) return 'Yağmur';
  if ([71, 73, 75].contains(code)) return 'Kar';
  if ([80, 81, 82].contains(code)) return 'Sağanak';
  if ([95, 96, 99].contains(code)) return 'Fırtına';
  return 'Hava';
}

/* --------------------------------- WIDGETS -------------------------------- */

class _TopBar extends StatelessWidget {
  final int count;
  final WeatherStore weather;
  final VoidCallback onTapWeather;
  final VoidCallback onRefreshWeather;
  final VoidCallback onTapHistory;

  const _TopBar({
    required this.count,
    required this.weather,
    required this.onTapWeather,
    required this.onRefreshWeather,
    required this.onTapHistory,
  });

  @override
  Widget build(BuildContext context) {
    final temp = weather.now?.temperatureC;
    final label = weather.loading ? '...' : (temp == null ? 'Hava' : '${temp.toStringAsFixed(0)}°');

    return Row(
      children: [
        const Expanded(
          child: Text(
            'Outfit Studio',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
          ),
        ),
        _PillButton(
          text: label,
          icon: Icons.cloud_rounded,
          onTap: onTapWeather,
          onLongPress: onRefreshWeather,
        ),
        const SizedBox(width: 10),
        _PillButton(
          text: 'Geçmiş',
          icon: Icons.history_rounded,
          onTap: onTapHistory,
        ),
        const SizedBox(width: 10),
        _PillButton(
          text: '$count',
          icon: Icons.checkroom_rounded,
          onTap: () {},
        ),
      ],
    );
  }
}

class _PillButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _PillButton({
    required this.text,
    required this.icon,
    required this.onTap,
    this.onLongPress,
  });

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
            const SizedBox(width: 8),
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
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFEAF0FF))),
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
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 10),
          )
        ],
      ),
      child: child,
    );
  }
}

class _SafeFileImage extends StatelessWidget {
  final String path;
  final BoxFit fit;
  final double? width;
  final double? height;

  const _SafeFileImage({
    required this.path,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(path);

    return Image.file(
      file,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: Colors.white.withOpacity(0.06),
          alignment: Alignment.center,
          child: Icon(
            Icons.broken_image_rounded,
            color: Colors.white.withOpacity(0.45),
          ),
        );
      },
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;

  const _PrimaryButton({required this.text, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              const Color(0xFF00E5FF).withOpacity(0.22),
              const Color(0xFF7C4DFF).withOpacity(0.18),
            ],
          ),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF00E5FF)),
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
    return Text(
      text,
      style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
    );
  }
}

class _SelectChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SelectChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF00E5FF).withOpacity(0.20) : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? const Color(0xFF00E5FF) : Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: selected ? const Color(0xFF00E5FF) : const Color(0xFFA9B3D6)),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: selected ? const Color(0xFFEAF0FF) : const Color(0xFFEAF0FF),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  const _TextField({required this.controller, required this.hint, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: Color(0xFFEAF0FF)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
        filled: true,
        fillColor: Colors.white.withOpacity(0.06),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF00E5FF)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF00E5FF)),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w800, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ClosetCard extends StatelessWidget {
  final ClothingItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ClosetCard({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: _SafeFileImage(path: item.imagePath),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.category, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF))),
                  const SizedBox(height: 4),
                  Text(
                    '${item.color} • ${item.warmths.map(_warmthNameStatic).join(', ')} • ${item.laundry.label}',
                    style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _warmthNameStatic(int w) {
    switch (w) {
      case 1:
        return 'İnce';
      case 2:
        return 'Orta';
      case 3:
        return 'Kalın';
      default:
        return '$w';
    }
  }
}

class _FilterChipRow extends StatelessWidget {
  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onPick;

  final String Function(String) display;

  const _FilterChipRow({
    required this.label,
    required this.value,
    required this.values,
    required this.onPick,
    this.display = _identity,
  });

  static String _identity(String v) => v;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          backgroundColor: const Color(0xFF0B1030),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
          builder: (sheetCtx) {
            final maxH = MediaQuery.of(sheetCtx).size.height * 0.70;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    children: [
                      Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.20),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(label,
                            style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.builder(
                          itemCount: values.length,
                          itemBuilder: (_, i) {
                            final v = values[i];
                            final selected = v == value;
                            return ListTile(
                              onTap: () => Navigator.pop(sheetCtx, v),
                              title: Text(
                                display(v),
                                style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w800),
                              ),
                              trailing: selected
                                  ? const Icon(Icons.check_rounded, color: Color(0xFF00E5FF))
                                  : null,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );

        if (picked != null) onPick(picked);
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withOpacity(0.06),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Color(0xFFA9B3D6), fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    display(value),
                    style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
                  ),
                ],
              ),
            ),
            const Icon(Icons.tune_rounded, color: Color(0xFF00E5FF), size: 18),
          ],
        ),
      ),
    );
  }
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

  List<String> _itemIds() {
    final ids = <String>{
      suggestion.top.id,
      suggestion.bottom.id,
      if (suggestion.outer != null) suggestion.outer!.id,
      if (suggestion.shoes != null) suggestion.shoes!.id,
      if (suggestion.accessory != null) suggestion.accessory!.id,
    };
    return ids.toList();
  }

  @override
  Widget build(BuildContext context) {
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
                const Icon(Icons.auto_awesome_rounded, color: Color(0xFF00E5FF)),
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
            _PrimaryButton(
              text: 'Giydim',
              icon: Icons.check_circle_rounded,
              onTap: () async {
                if (store.logOutfitBusy) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('İşleniyor...')),
                  );
                  return;
                }
                final added = await store.logOutfit(
                  itemIds: _itemIds(),
                  event: event,
                  weatherBucket: weather.bucket,
                  tempC: weather.now?.temperatureC,
                  raining: (weather.now?.precipitationMm ?? 0) > 0.2,
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      added ? 'Geçmişe eklendi' : 'Bu kombin zaten geçmişte var. Silmeden tekrar eklenmez.',
                    ),
                  ),
                );
              },
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
                color: Colors.black.withOpacity(0.35),
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFFEAF0FF)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* --------------------------------- CONSTANTS ------------------------------ */

class CategoryDef {
  final String code;
  final String label;
  final IconData icon;
  const CategoryDef(this.code, this.label, this.icon);
}

class WarmthDef {
  final int value;
  final String label;
  final IconData icon;
  const WarmthDef(this.value, this.label, this.icon);
}

class OccasionDef {
  final String code;
  final String label;
  final IconData icon;
  const OccasionDef(this.code, this.label, this.icon);
}

const kCategories = <CategoryDef>[
  CategoryDef('TOP', 'Üst', Icons.checkroom_rounded),
  CategoryDef('BOTTOM', 'Alt', Icons.style_rounded),
  CategoryDef('OUTER', 'Dış', Icons.layers_rounded),
  CategoryDef('SHOES', 'Ayakkabı', Icons.hiking_rounded),
  CategoryDef('ACCESSORY', 'Aksesuar', Icons.watch_rounded),
];

const kColors = <String>[
  'Black',
  'White',
  'Gray',
  'Beige',
  'Blue',
  'Red',
  'Green',
  'Brown',
  'Yellow',
  'Purple',
];

const kWarmths = <WarmthDef>[
  WarmthDef(1, 'İnce', Icons.ac_unit_rounded),
  WarmthDef(2, 'Orta', Icons.thermostat_rounded),
  WarmthDef(3, 'Kalın', Icons.local_fire_department_rounded),
];

const kOccasions = <OccasionDef>[
  OccasionDef('casual', 'Günlük', Icons.sentiment_satisfied_alt_rounded),
  OccasionDef('sport', 'Spor', Icons.fitness_center_rounded),
  OccasionDef('smart', 'Smart', Icons.business_center_rounded),
  OccasionDef('formal', 'Formal', Icons.star_rounded),
];
