import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = OutfitStore();
  final weather = WeatherStore()..refresh(); // otomatik konum + hava
  runApp(OutfitApp(store: store, weather: weather));
}

/* -------------------- DATA -------------------- */

class ClothingItem {
  final String id;

  // Foto: bytes (web ile uyumlu, test için yeterli)
  final Uint8List? imageBytes;
  final String? imageName;

  final String category; // TOP/BOTTOM/OUTER/SHOES/ACCESSORY
  final String color; // Black/White/Red...

  final String note;
  final DateTime createdAt;

  // Çoklu etiketler
  // warmths: 1=İnce 2=Orta 3=Kalın
  final List<int> warmths;

  // occasions: casual / sport / smart / formal
  final List<String> occasions;

  ClothingItem({
    required this.id,
    required this.imageBytes,
    required this.imageName,
    required this.category,
    required this.color,
    required this.note,
    required this.createdAt,
    required this.warmths,
    required this.occasions,
  });

  bool supportsWarmth(int w) => warmths.contains(w);
  bool supportsOccasion(String o) => occasions.contains(o);
}

class OutfitStore extends ChangeNotifier {
  final List<ClothingItem> _items = [];
  List<ClothingItem> get items => List.unmodifiable(_items);

  void add(ClothingItem item) {
    _items.insert(0, item);
    notifyListeners();
  }

  void removeById(String id) {
    _items.removeWhere((e) => e.id == id);
    notifyListeners();
  }
}

/* -------------------- WEATHER -------------------- */

class WeatherNow {
  final DateTime time;
  final double temperatureC;
  final double windKmh;
  final double precipitationMm;
  final int weatherCode;

  WeatherNow({
    required this.time,
    required this.temperatureC,
    required this.windKmh,
    required this.precipitationMm,
    required this.weatherCode,
  });

  String get summaryTr => WeatherService.wmoCodeToTr(weatherCode);
}

class WeatherHour {
  final DateTime time;
  final double temperatureC;
  final int precipProb; // %
  final double precipitationMm;
  final double windKmh;
  final int weatherCode;

  WeatherHour({
    required this.time,
    required this.temperatureC,
    required this.precipProb,
    required this.precipitationMm,
    required this.windKmh,
    required this.weatherCode,
  });

  String get summaryTr => WeatherService.wmoCodeToTr(weatherCode);
}

class WeatherService {
  static const _apiHost = 'api.open-meteo.com';

  static Future<(WeatherNow, List<WeatherHour>)> fetchCurrentAndHourly({
    required double latitude,
    required double longitude,
    int forecastHours = 24,
  }) async {
    final params = <String, String>{
      'latitude': latitude.toStringAsFixed(5),
      'longitude': longitude.toStringAsFixed(5),
      'timezone': 'auto',
      'wind_speed_unit': 'kmh',
      'precipitation_unit': 'mm',
      'temperature_unit': 'celsius',
      'current': 'temperature_2m,precipitation,weather_code,wind_speed_10m',
      'hourly': 'temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m',
      'forecast_hours': '$forecastHours',
    };

    final uri = Uri.https(_apiHost, '/v1/forecast', params);
    final resp = await http.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw Exception('Hava servisi hata: HTTP ${resp.statusCode}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;

    final current = (data['current'] as Map).cast<String, dynamic>();
    final now = WeatherNow(
      time: DateTime.tryParse(current['time']?.toString() ?? '') ?? DateTime.now(),
      temperatureC: (current['temperature_2m'] as num).toDouble(),
      windKmh: (current['wind_speed_10m'] as num?)?.toDouble() ?? 0,
      precipitationMm: (current['precipitation'] as num?)?.toDouble() ?? 0,
      weatherCode: (current['weather_code'] as num?)?.toInt() ?? 0,
    );

    final hourly = (data['hourly'] as Map?)?.cast<String, dynamic>();
    if (hourly == null) return (now, <WeatherHour>[]);


    final times = (hourly['time'] as List).map((e) => e.toString()).toList();
    final temps = (hourly['temperature_2m'] as List).map((e) => (e as num).toDouble()).toList();
    final probs = (hourly['precipitation_probability'] as List?)?.map((e) => (e as num).toInt()).toList() ?? List.filled(times.length, 0);
    final precs = (hourly['precipitation'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? List.filled(times.length, 0.0);
    final codes = (hourly['weather_code'] as List?)?.map((e) => (e as num).toInt()).toList() ?? List.filled(times.length, 0);
    final winds = (hourly['wind_speed_10m'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? List.filled(times.length, 0.0);

    final out = <WeatherHour>[];
    final n = min(times.length, min(temps.length, min(probs.length, min(precs.length, min(codes.length, winds.length)))));
    for (var i = 0; i < n; i++) {
      out.add(
        WeatherHour(
          time: DateTime.tryParse(times[i]) ?? DateTime.now().add(Duration(hours: i)),
          temperatureC: temps[i],
          precipProb: probs[i],
          precipitationMm: precs[i],
          windKmh: winds[i],
          weatherCode: codes[i],
        ),
      );
    }

    return (now, out);
  }

  // Cold/Mild/Hot bucket
  static String bucketFromTemperature(double t) {
    if (t <= 12) return 'Cold';
    if (t <= 20) return 'Mild';
    return 'Hot';
  }

  static int warmthFromTemperature(double t) {
    if (t <= 12) return 3;
    if (t <= 20) return 2;
    return 1;
  }

  static String warmthLabel(int w) {
    switch (w) {
      case 1:
        return 'İnce';
      case 2:
        return 'Orta';
      case 3:
        return 'Kalın';
      default:
        return 'Bilinmiyor';
    }
  }

  static String wmoCodeToTr(int code) {
    switch (code) {
      case 0:
        return 'Açık';
      case 1:
        return 'Az bulutlu';
      case 2:
        return 'Parçalı bulutlu';
      case 3:
        return 'Kapalı';
      case 45:
      case 48:
        return 'Sis';
      case 51:
      case 53:
      case 55:
        return 'Çiseleme';
      case 56:
      case 57:
        return 'Donan çiseleme';
      case 61:
      case 63:
      case 65:
        return 'Yağmur';
      case 66:
      case 67:
        return 'Donan yağmur';
      case 71:
      case 73:
      case 75:
        return 'Kar';
      case 77:
        return 'Kar taneleri';
      case 80:
      case 81:
      case 82:
        return 'Sağanak';
      case 85:
      case 86:
        return 'Kar sağanağı';
      case 95:
        return 'Gök gürültülü';
      case 96:
      case 99:
        return 'Dolu / fırtına';
      default:
        return 'Bilinmiyor';
    }
  }
}

class WeatherStore extends ChangeNotifier {
  bool loading = false;
  String? error;

  WeatherNow? now;
  List<WeatherHour> hourly = const [];

  DateTime? updatedAt;

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        throw Exception('Konum servisi kapalı. (Telefon ayarlarından aç)');
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        throw Exception('Konum izni verilmedi.');
      }
      if (perm == LocationPermission.deniedForever) {
        throw Exception('Konum izni kalıcı olarak reddedildi. Ayarlardan izin ver.');
      }

      // Weather için yüksek hassasiyet gereksiz; hızlı gelsin diye low/medium.
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );

      final (n, h) = await WeatherService.fetchCurrentAndHourly(
        latitude: pos.latitude,
        longitude: pos.longitude,
        forecastHours: 24,
      );

      now = n;
      hourly = h;
      updatedAt = DateTime.now();
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  String get bucket {
    final n = now;
    if (n == null) return 'Mild';
    return WeatherService.bucketFromTemperature(n.temperatureC);
  }

  int get desiredWarmth {
    final n = now;
    if (n == null) return 2;
    return WeatherService.warmthFromTemperature(n.temperatureC);
  }
}

/* -------------------- APP -------------------- */

class OutfitApp extends StatelessWidget {
  final OutfitStore store;
  final WeatherStore weather;
  const OutfitApp({super.key, required this.store, required this.weather});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Outfit Studio',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF070A1A),
      ),
      home: HomePage(store: store, weather: weather),
    );
  }
}

/* -------------------- HOME -------------------- */

class HomePage extends StatelessWidget {
  final OutfitStore store;
  final WeatherStore weather;

  const HomePage({super.key, required this.store, required this.weather});

  void _openWeatherSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1030),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.75;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: AnimatedBuilder(
                animation: weather,
                builder: (_, __) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.20),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Text(
                            'Hava Durumu',
                            style: TextStyle(color: Color(0xFFEAF0FF), fontSize: 18, fontWeight: FontWeight.w900),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: weather.loading ? null : () => weather.refresh(),
                            icon: weather.loading
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.refresh_rounded, color: Color(0xFF00E5FF)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (weather.error != null) ...[
                        Text(
                          weather.error!,
                          style: const TextStyle(color: Color(0xFFFF8A80), fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Not: Konum izni vermeden otomatik hava çekemiyoruz.',
                          style: TextStyle(color: Color(0xFFA9B3D6)),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _NeonButton(
                                label: 'Ayarlara Git',
                                onTap: () => Geolocator.openAppSettings(),
                              ),
                            ),
                          ],
                        ),
                      ] else if (weather.now == null) ...[
                        const Text('Hava bilgisi yok.', style: TextStyle(color: Color(0xFFA9B3D6))),
                      ] else ...[
                        _WeatherNowCard(now: weather.now!, bucket: weather.bucket),
                        const SizedBox(height: 12),
                        const Text(
                          'Saatlik Tahmin (24s)',
                          style: TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 10),
                        Expanded(child: _HourlyForecastList(hours: weather.hourly)),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _NeonBackground(
        child: SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge([store, weather]),
            builder: (_, __) {
              final wxNow = weather.now;
              final wxLabel = (wxNow == null)
                  ? 'Hava'
                  : '${wxNow.temperatureC.toStringAsFixed(0)}° • ${wxNow.summaryTr}';

              return ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
                children: [
                  _TopBar(
                    count: store.items.length,
                    weatherLabel: wxLabel,
                    onWeatherTap: () => _openWeatherSheet(context),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Outfit Studio',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFFEAF0FF),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Dolabını düzenle, hava + etkinliğe göre kombin önerisi al.',
                    style: TextStyle(color: Color(0xFFA9B3D6), height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _GlassCard(
                          child: _HomeAction(
                            title: 'Kıyafet Ekle',
                            subtitle: 'Foto + etiketler',
                            icon: Icons.add_circle_rounded,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => AddClothingPage(store: store)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _GlassCard(
                          child: _HomeAction(
                            title: 'Dolabım',
                            subtitle: 'Arama + filtre',
                            icon: Icons.inventory_2_rounded,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => ClosetPage(store: store)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _GlassCard(
                    child: _HomeAction(
                      title: 'Kombin Oluştur',
                      subtitle: 'Hava otomatik',
                      icon: Icons.auto_awesome_rounded,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => OutfitPlannerPage(store: store, weather: weather)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Hızlı başlangıç',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFFEAF0FF)),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _Pill(
                        text: 'Kafe',
                        icon: Icons.local_cafe_rounded,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => OutfitPlannerPage(store: store, weather: weather, initialEvent: 'cafe')),
                        ),
                      ),
                      _Pill(
                        text: 'Spor',
                        icon: Icons.sports_gymnastics_rounded,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => OutfitPlannerPage(store: store, weather: weather, initialEvent: 'sport')),
                        ),
                      ),
                      _Pill(
                        text: 'Ofis',
                        icon: Icons.work_rounded,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => OutfitPlannerPage(store: store, weather: weather, initialEvent: 'office')),
                        ),
                      ),
                      _Pill(
                        text: 'Akşam',
                        icon: Icons.nightlife_rounded,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => OutfitPlannerPage(store: store, weather: weather, initialEvent: 'dinner')),
                        ),
                      ),
                      _Pill(
                        text: 'Formal',
                        icon: Icons.stars_rounded,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => OutfitPlannerPage(store: store, weather: weather, initialEvent: 'formal')),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.tips_and_updates_rounded, color: Color(0xFF00E5FF)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Not: Hava otomatik. Konum izni vermezsen varsayılan Mild ile öneri verir.',
                              style: TextStyle(color: Colors.white.withOpacity(0.75), height: 1.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final int count;
  final VoidCallback onWeatherTap;
  final String weatherLabel;

  const _TopBar({
    required this.count,
    required this.onWeatherTap,
    required this.weatherLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white.withOpacity(0.06),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: const Icon(Icons.checkroom_rounded, color: Color(0xFFEAF0FF)),
        ),
        const SizedBox(width: 10),
        _CountPill(count: count),
        const Spacer(),
        InkWell(
          onTap: onWeatherTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Colors.white.withOpacity(0.06),
              border: Border.all(color: Colors.white.withOpacity(0.10)),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_rounded, size: 18, color: Color(0xFF00E5FF)),
                const SizedBox(width: 8),
                Text(weatherLabel, style: const TextStyle(color: Color(0xFFA9B3D6))),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  final int count;
  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        children: [
          const Icon(Icons.inventory_2_rounded, size: 18, color: Color(0xFFB388FF)),
          const SizedBox(width: 8),
          Text('$count', style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
          const SizedBox(width: 6),
          const Text('parça', style: TextStyle(color: Color(0xFFA9B3D6))),
        ],
      ),
    );
  }
}

/* -------------------- ADD CLOTHING -------------------- */

class AddClothingPage extends StatefulWidget {
  final OutfitStore store;
  const AddClothingPage({super.key, required this.store});

  @override
  State<AddClothingPage> createState() => _AddClothingPageState();
}

class _AddClothingPageState extends State<AddClothingPage> {
  final _picker = ImagePicker();

  Uint8List? _pickedBytes;
  String? _pickedName;

  String _category = 'TOP';
  String _color = 'Black';
  final TextEditingController _note = TextEditingController();

  // Multi-select
  final Set<int> _warmths = {2};
  final Set<String> _occasions = {'casual'};

  static const _categories = [
    ('TOP', Icons.checkroom_rounded),
    ('BOTTOM', Icons.straighten_rounded),
    ('OUTER', Icons.layers_rounded),
    ('SHOES', Icons.hiking_rounded),
    ('ACCESSORY', Icons.watch_rounded),
  ];

  static const _colors = [
    'Black',
    'White',
    'Gray',
    'Red',
    'Blue',
    'Green',
    'Beige',
    'Brown',
    'Yellow',
    'Purple',
  ];

  static const _warmthChoices = [
    (1, 'İnce', Icons.ac_unit_rounded),
    (2, 'Orta', Icons.thermostat_rounded),
    (3, 'Kalın', Icons.local_fire_department_rounded),
  ];

  static const _occasionChoices = [
    ('casual', 'Günlük', Icons.sentiment_satisfied_rounded),
    ('sport', 'Spor', Icons.sports_gymnastics_rounded),
    ('smart', 'Smart', Icons.auto_awesome_rounded),
    ('formal', 'Formal', Icons.stars_rounded),
  ];

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
        _pickedBytes = bytes;
        _pickedName = file.name;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Foto seçme başarısız: $e')),
      );
    }
  }

  void _toggleWarmth(int w) {
    setState(() {
      if (_warmths.contains(w)) {
        if (_warmths.length > 1) _warmths.remove(w);
      } else {
        _warmths.add(w);
      }
    });
  }

  void _toggleOccasion(String o) {
    setState(() {
      if (_occasions.contains(o)) {
        if (_occasions.length > 1) _occasions.remove(o);
      } else {
        _occasions.add(o);
      }
    });
  }

  void _save() {
    if (_pickedBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Önce foto seç.')));
      return;
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();

    // Aksesuarlar için kalınlık seçimi yok: her sıcaklıkta kabul.
    final warmths = (_category == 'ACCESSORY') ? <int>[1, 2, 3] : _warmths.toList()..sort();

    final item = ClothingItem(
      id: id,
      imageBytes: _pickedBytes,
      imageName: _pickedName,
      category: _category,
      color: _color,
      note: _note.text.trim(),
      createdAt: DateTime.now(),
      warmths: warmths,
      occasions: _occasions.toList()..sort(),
    );

    widget.store.add(item);
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kıyafet Ekle'),
        backgroundColor: const Color(0xFF070A1A),
      ),
      body: _NeonBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 22),
          children: [
            _GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Fotoğraf', style: TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        height: 180,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: Colors.white.withOpacity(0.06),
                          border: Border.all(color: Colors.white.withOpacity(0.10)),
                        ),
                        child: _pickedBytes == null
                            ? const Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.add_photo_alternate_rounded, color: Color(0xFF00E5FF), size: 32),
                                    SizedBox(height: 8),
                                    Text('Foto seç', style: TextStyle(color: Color(0xFFA9B3D6))),
                                  ],
                                ),
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(18),
                                child: Image.memory(_pickedBytes!, fit: BoxFit.cover),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _RowLabelValue(
                      label: 'Kategori',
                      child: _ChoiceChips(
                        values: _categories.map((e) => e.$1).toList(),
                        selected: _category,
                        iconFor: (s) => _categories.firstWhere((e) => e.$1 == s).$2,
                        onPick: (v) => setState(() => _category = v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _RowLabelValue(
                      label: 'Renk',
                      child: _ChoiceChips(
                        values: _colors,
                        selected: _color,
                        onPick: (v) => setState(() => _color = v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_category != 'ACCESSORY') ...[
                      const Text('Kalınlık (çoklu)', style: TextStyle(color: Color(0xFFA9B3D6))),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: _warmthChoices.map((w) {
                          final val = w.$1;
                          final sel = _warmths.contains(val);
                          return _MultiChip(
                            label: w.$2,
                            icon: w.$3,
                            selected: sel,
                            onTap: () => _toggleWarmth(val),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const Text('Ortam (çoklu)', style: TextStyle(color: Color(0xFFA9B3D6))),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: _occasionChoices.map((o) {
                        final key = o.$1;
                        final sel = _occasions.contains(key);
                        return _MultiChip(
                          label: o.$2,
                          icon: o.$3,
                          selected: sel,
                          onTap: () => _toggleOccasion(key),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _note,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Not (opsiyonel)',
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _NeonButton(label: 'Kaydet', onTap: _save),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* -------------------- CLOSET -------------------- */

class ClosetPage extends StatefulWidget {
  final OutfitStore store;
  const ClosetPage({super.key, required this.store});

  @override
  State<ClosetPage> createState() => _ClosetPageState();
}

class _ClosetPageState extends State<ClosetPage> {
  String _category = 'ALL';
  String _color = 'ALL';
  String _occasion = 'ALL';
  String _warmth = 'ALL';
  String _query = '';

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

  String _occasionLabel(String v) {
    switch (v) {
      case 'ALL':
        return 'Hepsi';
      case 'casual':
        return 'Günlük';
      case 'sport':
        return 'Spor';
      case 'smart':
        return 'Smart';
      case 'formal':
        return 'Formal';
      default:
        return v;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dolabım'),
        backgroundColor: const Color(0xFF070A1A),
      ),
      body: _NeonBackground(
        child: AnimatedBuilder(
          animation: store,
          builder: (_, __) {
            final items = store.items.where((it) {
              if (_category != 'ALL' && it.category != _category) return false;
              if (_color != 'ALL' && it.color != _color) return false;

              // Ortam çoklu: item.occasions içinde olmalı
              if (_occasion != 'ALL' && !it.supportsOccasion(_occasion)) return false;

              // Kalınlık çoklu: warmth listesi içinde olmalı
              if (_warmth != 'ALL' && !it.supportsWarmth(int.parse(_warmth))) return false;

              final q = _query.trim().toLowerCase();
              if (q.isEmpty) return true;

              final hay = [
                it.category,
                it.color,
                it.note,
                it.occasions.join(','),
                it.warmths.join(','),
              ].join(' ').toLowerCase();
              return hay.contains(q);
            }).toList();

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 22),
              children: [
                _GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          onChanged: (v) => setState(() => _query = v),
                          decoration: InputDecoration(
                            hintText: 'Ara (renk, not, ortam...)',
                            prefixIcon: const Icon(Icons.search_rounded),
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.06),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _FilterChipRow(
                                label: 'Kategori',
                                value: _category,
                                values: const ['ALL', 'TOP', 'BOTTOM', 'OUTER', 'SHOES', 'ACCESSORY'],
                                onPick: (v) => setState(() => _category = v),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _FilterChipRow(
                                label: 'Renk',
                                value: _color,
                                values: const ['ALL', 'Black', 'White', 'Gray', 'Red', 'Blue', 'Green', 'Beige', 'Brown', 'Yellow', 'Purple'],
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
                                values: const ['ALL', 'casual', 'sport', 'smart', 'formal'],
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
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (items.isEmpty)
                  _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        children: const [
                          Icon(Icons.inbox_rounded, color: Color(0xFFA9B3D6)),
                          SizedBox(height: 8),
                          Text('Eşleşen kıyafet yok.', style: TextStyle(color: Color(0xFFA9B3D6))),
                        ],
                      ),
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: items.length,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.85,
                    ),
                    itemBuilder: (_, i) {
                      final it = items[i];
                      return _ClosetCard(
                        item: it,
                        onTap: () async {
                          final deleted = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(builder: (_) => ClothingDetailPage(store: store, item: it)),
                          );
                          if (deleted == true && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Silindi.')));
                          }
                        },
                        onLongPress: () {
                          store.removeById(it.id);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Silindi.')),
                          );
                        },
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ClosetCard extends StatelessWidget {
  final ClothingItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ClosetCard({required this.item, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(22),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            children: [
              Positioned.fill(
                child: item.imageBytes == null
                    ? Container(color: Colors.white.withOpacity(0.04))
                    : Image.memory(item.imageBytes!, fit: BoxFit.cover),
              ),
              Positioned(
                left: 10,
                bottom: 10,
                right: 10,
                child: Row(
                  children: [
                    _Badge(text: item.category),
                    const Spacer(),
                    _Badge(text: item.color),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ClothingDetailPage extends StatelessWidget {
  final OutfitStore store;
  final ClothingItem item;
  const ClothingDetailPage({super.key, required this.store, required this.item});

  @override
  Widget build(BuildContext context) {
    final warmthText = item.warmths.map(WeatherService.warmthLabel).join(', ');
    final occText = item.occasions.map((o) {
      switch (o) {
        case 'casual':
          return 'Günlük';
        case 'sport':
          return 'Spor';
        case 'smart':
          return 'Smart';
        case 'formal':
          return 'Formal';
        default:
          return o;
      }
    }).join(', ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Detay'),
        backgroundColor: const Color(0xFF070A1A),
      ),
      body: _NeonBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 22),
          children: [
            _GlassCard(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: AspectRatio(
                  aspectRatio: 1.2,
                  child: item.imageBytes == null
                      ? Container(color: Colors.white.withOpacity(0.04))
                      : Image.memory(item.imageBytes!, fit: BoxFit.cover),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _Badge(text: item.category),
                        _Badge(text: item.color),
                        _Badge(text: warmthText),
                        _Badge(text: occText),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(item.note.isEmpty ? 'Not yok' : item.note, style: const TextStyle(color: Color(0xFFA9B3D6), height: 1.35)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _NeonButton(
                            label: 'Sil',
                            onTap: () {
                              store.removeById(item.id);
                              Navigator.pop(context, true);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* -------------------- OUTFIT PLANNER -------------------- */

class OutfitPlannerPage extends StatefulWidget {
  final OutfitStore store;
  final WeatherStore weather;
  final String? initialEvent;
  const OutfitPlannerPage({super.key, required this.store, required this.weather, this.initialEvent});

  @override
  State<OutfitPlannerPage> createState() => _OutfitPlannerPageState();
}

class _OutfitPlannerPageState extends State<OutfitPlannerPage> {
  String _event = 'cafe';

  static const _events = ['sport', 'cafe', 'office', 'dinner', 'formal'];

  @override
  void initState() {
    super.initState();
    _event = widget.initialEvent ?? _event;
  }

  String _eventLabel(String v) {
    switch (v) {
      case 'sport':
        return 'Spor';
      case 'cafe':
        return 'Kafe';
      case 'office':
        return 'Ofis';
      case 'dinner':
        return 'Akşam';
      case 'formal':
        return 'Formal';
      default:
        return v;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final weather = widget.weather;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kombin Oluştur'),
        backgroundColor: const Color(0xFF070A1A),
        actions: [
          IconButton(
            onPressed: weather.loading ? null : () => weather.refresh(),
            icon: weather.loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, color: Color(0xFF00E5FF)),
            tooltip: 'Havayı güncelle',
          ),
        ],
      ),
      body: _NeonBackground(
        child: AnimatedBuilder(
          animation: Listenable.merge([store, weather]),
          builder: (_, __) {
            final bucket = weather.bucket;
            final desiredWarmth = weather.desiredWarmth;

            final suggestions = _generateTop3(
              items: store.items,
              weatherBucket: bucket,
              desiredWarmth: desiredWarmth,
              event: _event,
              hasWeather: weather.now != null,
              strictEvent: true,
            );

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 22),
              children: [
                // Weather display (no location change UI)
                _GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Hava (otomatik)', style: TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
                        const SizedBox(height: 10),
                        if (weather.error != null) ...[
                          Text(weather.error!, style: const TextStyle(color: Color(0xFFFF8A80), fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: _NeonButton(label: 'Ayarlara Git', onTap: () => Geolocator.openAppSettings())),
                            ],
                          ),
                        ] else if (weather.now == null) ...[
                          const Text('Hava bilgisi yok (varsayılan Mild).', style: TextStyle(color: Color(0xFFA9B3D6))),
                        ] else ...[
                          _WeatherNowCard(now: weather.now!, bucket: bucket),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 92,
                            child: _HourlyForecastList(hours: weather.hourly.take(12).toList()),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Event filter (fix: actually filters the pool)
                Row(
                  children: [
                    Expanded(
                      child: _FilterChipRow(
                        label: 'Etkinlik',
                        value: _event,
                        values: _events,
                        display: _eventLabel,
                        onPick: (v) => setState(() => _event = v),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Kalınlık hedefi', style: TextStyle(color: Color(0xFFA9B3D6), fontSize: 12)),
                              const SizedBox(height: 4),
                              Text(
                                WeatherService.warmthLabel(desiredWarmth),
                                style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                if (store.items.isEmpty) ...[
                  _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        children: const [
                          Icon(Icons.inbox_rounded, color: Color(0xFFA9B3D6)),
                          SizedBox(height: 8),
                          Text('Önce dolabına kıyafet ekle.', style: TextStyle(color: Color(0xFFA9B3D6))),
                        ],
                      ),
                    ),
                  ),
                ] else if (suggestions.isEmpty) ...[
                  _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Uygun kombin yok.', style: TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
                          const SizedBox(height: 8),
                          Text(
                            'Seçili etkinlik için ($_event) işaretlenmiş kıyafet sayın az olabilir. '
                            'Kıyafet eklerken ortam etiketlerini doğru seç.',
                            style: const TextStyle(color: Color(0xFFA9B3D6), height: 1.35),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  for (var i = 0; i < suggestions.length; i++) ...[
                    _SuggestionCard(
                      title: 'Öneri ${i + 1}',
                      outfit: suggestions[i],
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/* -------------------- RECOMMENDATION ENGINE -------------------- */

class OutfitSuggestion {
  final ClothingItem top;
  final ClothingItem bottom;
  final ClothingItem? outer;
  final ClothingItem? shoes;
  final ClothingItem? accessory;
  final double score;

  OutfitSuggestion({
    required this.top,
    required this.bottom,
    required this.outer,
    required this.shoes,
    required this.accessory,
    required this.score,
  });
}

List<OutfitSuggestion> _generateTop3({
  required List<ClothingItem> items,
  required String weatherBucket,
  required int desiredWarmth,
  required String event,
  required bool hasWeather,
  required bool strictEvent,
}) {
  // event filter: çalışsın diye havuzu burada filtreliyoruz
  bool eventOk(ClothingItem it) => it.supportsOccasion(event);

  final pool = strictEvent ? items.where(eventOk).toList() : items;

  // Eğer hiç event etiketli yoksa (kullanıcı hiç seçmemiş olabilir), fallback
  final effectivePool = pool.isEmpty ? items : pool;

  List<ClothingItem> byCat(String c) => effectivePool.where((e) => e.category == c).toList();

  List<ClothingItem> warmthFilter(List<ClothingItem> src) {
    final f = src.where((e) => e.supportsWarmth(desiredWarmth)).toList();
    return f.isEmpty ? src : f; // boş kalmasın diye fallback
  }

  final tops = warmthFilter(byCat('TOP'));
  final bottoms = warmthFilter(byCat('BOTTOM'));
  final outers = warmthFilter(byCat('OUTER'));
  final shoes = warmthFilter(byCat('SHOES'));
  final accs = byCat('ACCESSORY'); // aksesuar her sıcaklıkta kabul

  if (tops.isEmpty || bottoms.isEmpty) return const [];

  final wantOuter = weatherBucket == 'Cold'; // sıcaksa outer istemiyoruz
  final desiredOccasion = event; // event string already aligns

  double scoreItem(ClothingItem it) {
    var s = 0.0;

    // Warmth closeness
    s += _warmthBonus(desiredWarmth, it.warmths);

    // Occasion
    s += it.supportsOccasion(desiredOccasion) ? 8.0 : -6.0;

    // Weather bucket effect for OUTER
    if (it.category == 'OUTER') {
      if (weatherBucket == 'Cold') s += 8.0;
      if (weatherBucket == 'Hot') s -= 8.0;
    }

    // Note penalty for "dirty" etc.
    s -= _notePenalty(it.note);

    return s;
  }

  // Build 3 suggestions by random search + best score
  final rng = Random();
  final seen = <String>{};
  final results = <OutfitSuggestion>[];

  int tries = 0;
  while (results.length < 3 && tries < 120) {
    tries++;

    final top = tops[rng.nextInt(tops.length)];
    final bottom = bottoms[rng.nextInt(bottoms.length)];

    ClothingItem? outer;
    if (wantOuter && outers.isNotEmpty) {
      outer = _bestExtra(outers, scoreItem);
    }

    ClothingItem? sh;
    if (shoes.isNotEmpty) sh = _bestExtra(shoes, scoreItem);

    ClothingItem? acc;
    if (accs.isNotEmpty) acc = _bestExtra(accs, scoreItem);

    // Hot'ta outer hiç koyma (extra güvenlik)
    if (weatherBucket == 'Hot') outer = null;

    var score = 0.0;
    score += scoreItem(top);
    score += scoreItem(bottom);
    if (outer != null) score += scoreItem(outer);
    if (sh != null) score += scoreItem(sh);
    if (acc != null) score += scoreItem(acc);

    // Color harmony (simple)
    score += _colorScore(top.color, bottom.color);

    final key = '${top.id}-${bottom.id}-${outer?.id ?? "-"}-${sh?.id ?? "-"}-${acc?.id ?? "-"}';
    if (seen.contains(key)) continue;
    seen.add(key);

    results.add(
      OutfitSuggestion(
        top: top,
        bottom: bottom,
        outer: outer,
        shoes: sh,
        accessory: acc,
        score: score,
      ),
    );
  }

  results.sort((a, b) => b.score.compareTo(a.score));
  return results.take(3).toList();
}

ClothingItem _bestExtra(List<ClothingItem> items, double Function(ClothingItem) scoreItem) {
  ClothingItem best = items.first;
  double bestScore = -1e9;
  for (final it in items) {
    final s = scoreItem(it);
    if (s > bestScore) {
      bestScore = s;
      best = it;
    }
  }
  return best;
}

double _warmthBonus(int desired, List<int> warmths) {
  // Çoklu warmth: en yakın olanı al
  int bestDiff = 99;
  for (final w in warmths) {
    bestDiff = min(bestDiff, (w - desired).abs());
  }
  if (bestDiff == 0) return 10.0;
  if (bestDiff == 1) return 3.0;
  return -6.0;
}

double _colorScore(String a, String b) {
  if (a == b) return 4.0;
  // Simple neutrals
  const neutrals = {'Black', 'White', 'Gray', 'Beige', 'Brown'};
  final an = neutrals.contains(a);
  final bn = neutrals.contains(b);
  if (an && bn) return 3.0;
  if (an || bn) return 2.0;
  return 0.0;
}

double _notePenalty(String note) {
  final n = note.toLowerCase();
  if (n.contains('kirli') || n.contains('dirty') || n.contains('yıkanacak')) return 6.0;
  return 0.0;
}

/* -------------------- SUGGESTION UI -------------------- */

class _SuggestionCard extends StatelessWidget {
  final String title;
  final OutfitSuggestion outfit;

  const _SuggestionCard({required this.title, required this.outfit});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      Expanded(child: _OutfitTile(label: 'Top', item: outfit.top, accent: const Color(0xFFFF5252))),
      const SizedBox(width: 10),
      Expanded(child: _OutfitTile(label: 'Bottom', item: outfit.bottom, accent: const Color(0xFFB388FF))),
    ];

    // Outer: yoksa hiç çizme (boş kutu istemiyorsun)
    final extraRow = <Widget>[];
    if (outfit.outer != null) extraRow.add(Expanded(child: _OutfitTile(label: 'Outer', item: outfit.outer!, accent: const Color(0xFF00E5FF))));
    if (outfit.shoes != null) {
      if (extraRow.isNotEmpty) extraRow.add(const SizedBox(width: 10));
      extraRow.add(Expanded(child: _OutfitTile(label: 'Shoes', item: outfit.shoes!, accent: const Color(0xFFB2FF59))));
    }
    if (outfit.accessory != null) {
      if (extraRow.isNotEmpty) extraRow.add(const SizedBox(width: 10));
      extraRow.add(Expanded(child: _OutfitTile(label: 'Accessory', item: outfit.accessory!, accent: const Color(0xFFFFD54F))));
    }

    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
                const Spacer(),
                Text(
                  outfit.score.toStringAsFixed(1),
                  style: const TextStyle(color: Color(0xFFA9B3D6), fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(children: tiles),
            if (extraRow.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: extraRow),
            ],
          ],
        ),
      ),
    );
  }
}

class _OutfitTile extends StatelessWidget {
  final String label;
  final ClothingItem item;
  final Color accent;

  const _OutfitTile({required this.label, required this.item, required this.accent});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        children: [
          AspectRatio(
            aspectRatio: 1.15,
            child: item.imageBytes == null
                ? Container(color: Colors.white.withOpacity(0.04))
                : Image.memory(item.imageBytes!, fit: BoxFit.cover),
          ),
          Positioned(
            left: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: Colors.black.withOpacity(0.35),
                border: Border.all(color: accent.withOpacity(0.55)),
              ),
              child: Text(label, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}

/* -------------------- WEATHER UI -------------------- */

class _WeatherNowCard extends StatelessWidget {
  final WeatherNow now;
  final String bucket;
  const _WeatherNowCard({required this.now, required this.bucket});

  @override
  Widget build(BuildContext context) {
    final warmth = WeatherService.warmthLabel(WeatherService.warmthFromTemperature(now.temperatureC));
    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.cloud_rounded, color: Color(0xFF00E5FF)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${now.temperatureC.toStringAsFixed(1)}° • ${now.summaryTr}',
                    style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Rüzgar ${now.windKmh.toStringAsFixed(0)} km/h • Yağış ${now.precipitationMm.toStringAsFixed(1)} mm • Hedef: $warmth ($bucket)',
                    style: const TextStyle(color: Color(0xFFA9B3D6), height: 1.3),
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

class _HourlyForecastList extends StatelessWidget {
  final List<WeatherHour> hours;
  const _HourlyForecastList({required this.hours});

  @override
  Widget build(BuildContext context) {
    if (hours.isEmpty) {
      return const Center(child: Text('Saatlik veri yok', style: TextStyle(color: Color(0xFFA9B3D6))));
    }
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: hours.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (_, i) {
        final h = hours[i];
        final t = TimeOfDay.fromDateTime(h.time).format(context);
        return Container(
          width: 118,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Colors.white.withOpacity(0.06),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t, style: const TextStyle(color: Color(0xFFA9B3D6), fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('${h.temperatureC.toStringAsFixed(0)}°', style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900, fontSize: 18)),
              const SizedBox(height: 4),
              Text(h.summaryTr, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFA9B3D6))),
              const Spacer(),
              Text('Yağış %${h.precipProb}', style: const TextStyle(color: Color(0xFFA9B3D6), fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}

/* -------------------- SMALL UI PARTS -------------------- */

class _HomeAction extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _HomeAction({required this.title, required this.subtitle, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Colors.white.withOpacity(0.06),
                border: Border.all(color: Colors.white.withOpacity(0.10)),
              ),
              child: Icon(icon, color: const Color(0xFF00E5FF)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: Color(0xFFA9B3D6))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFFA9B3D6)),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  const _Pill({required this.text, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Colors.white.withOpacity(0.06),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFFB388FF)),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

class _NeonButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _NeonButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFFB388FF)]),
          boxShadow: [
            BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.25), blurRadius: 18, offset: const Offset(0, 8)),
          ],
        ),
        child: Center(
          child: Text(label, style: const TextStyle(color: Color(0xFF070A1A), fontWeight: FontWeight.w900)),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.black.withOpacity(0.28),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Text(text, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: Colors.white.withOpacity(0.06),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _NeonBackground extends StatelessWidget {
  final Widget child;
  const _NeonBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.2,
                colors: [Color(0xFF151A3B), Color(0xFF070A1A)],
              ),
            ),
          ),
        ),
        Positioned(
          top: -120,
          right: -90,
          child: _GlowBlob(color: const Color(0xFF00E5FF).withOpacity(0.35), size: 240),
        ),
        Positioned(
          bottom: -140,
          left: -80,
          child: _GlowBlob(color: const Color(0xFFB388FF).withOpacity(0.35), size: 280),
        ),
        child,
      ],
    );
  }
}

class _GlowBlob extends StatelessWidget {
  final Color color;
  final double size;
  const _GlowBlob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60), child: const SizedBox.shrink()),
    );
  }
}

class _RowLabelValue extends StatelessWidget {
  final String label;
  final Widget child;
  const _RowLabelValue({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFFA9B3D6))),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _ChoiceChips extends StatelessWidget {
  final List<String> values;
  final String selected;
  final void Function(String) onPick;
  final IconData Function(String)? iconFor;

  const _ChoiceChips({required this.values, required this.selected, required this.onPick, this.iconFor});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: values.map((v) {
        final isSel = v == selected;
        return InkWell(
          onTap: () => onPick(v),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: isSel ? const Color(0xFF00E5FF).withOpacity(0.16) : Colors.white.withOpacity(0.06),
              border: Border.all(color: isSel ? const Color(0xFF00E5FF) : Colors.white.withOpacity(0.10)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (iconFor != null) ...[
                  Icon(iconFor!(v), size: 16, color: isSel ? const Color(0xFF00E5FF) : const Color(0xFFA9B3D6)),
                  const SizedBox(width: 8),
                ],
                Text(v, style: TextStyle(color: isSel ? const Color(0xFFEAF0FF) : const Color(0xFFA9B3D6), fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _MultiChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _MultiChip({required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected ? const Color(0xFFB388FF).withOpacity(0.16) : Colors.white.withOpacity(0.06),
          border: Border.all(color: selected ? const Color(0xFFB388FF) : Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? const Color(0xFFB388FF) : const Color(0xFFA9B3D6)),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: selected ? const Color(0xFFEAF0FF) : const Color(0xFFA9B3D6), fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

/* -------------------- FILTER ROW -------------------- */

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
                        child: Text(
                          label,
                          style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
                        ),
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
                              trailing: selected ? const Icon(Icons.check_rounded, color: Color(0xFF00E5FF)) : null,
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
                  Text(display(value), style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
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
