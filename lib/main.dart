import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

void main() => runApp(OutfitApp(store: OutfitStore()));

class ClothingItem {
  final String id;
  final String? imagePath; // Android'de file path
  final String category;   // TOP/BOTTOM/OUTER/SHOES/ACCESSORY
  final String color;      // Black/White/Red...
  final String note;
  final DateTime createdAt;

  // NEW
  final int warmth;        // 1=Thin 2=Medium 3=Warm
  final String occasion;   // casual / sport / smart / formal

  ClothingItem({
    required this.id,
    required this.imagePath,
    required this.category,
    required this.color,
    required this.note,
    required this.createdAt,
    this.warmth = 2,
    this.occasion = 'casual',
  });
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

class OutfitApp extends StatelessWidget {
  final OutfitStore store;
  const OutfitApp({super.key, required this.store});

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
      home: HomePage(store: store),
    );
  }
}

class HomePage extends StatelessWidget {
  final OutfitStore store;
  const HomePage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const _NeonBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: AnimatedBuilder(
                animation: store,
                builder: (context, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _TopBar(count: store.items.length),
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
                        'Dolabını yükle, notlarını ekle. Hava + mekâna göre kombin önerelim.',
                        style: TextStyle(
                          color: Color(0xFFA9B3D6),
                          fontSize: 15,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Hızlı başlangıç',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFEAF0FF),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: const [
                                _Pill(text: 'Kafe', icon: Icons.local_cafe_rounded),
                                _Pill(text: 'Spor', icon: Icons.sports_gymnastics_rounded),
                                _Pill(text: 'Akşam', icon: Icons.restaurant_rounded),
                                _Pill(text: 'Ofis', icon: Icons.work_rounded),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: _PrimaryButton(
                                    text: 'Kıyafet Ekle',
                                    icon: Icons.add_rounded,
                                    onTap: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => AddClothingPage(store: store),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _OutlineButton(
                                    text: 'Dolabım',
                                    icon: Icons.grid_view_rounded,
                                    onTap: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ClosetPage(store: store),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _GlassCard(
                        child: Row(
                          children: [
                            const Icon(Icons.auto_awesome_rounded, color: Color(0xFF00E5FF)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                store.items.isEmpty
                                    ? 'Önce dolabı doldur. Sonra AI kombin önerisi yapacağız.'
                                    : 'Dolap doluyor. Sıradaki adım: kombin üretme ekranı.',
                                style: const TextStyle(color: Color(0xFFA9B3D6)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      const Text('v0.1 • Android prototype',
                          style: TextStyle(color: Color(0xFF6F7AA8))),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AddClothingPage extends StatefulWidget {
  final OutfitStore store;
  const AddClothingPage({super.key, required this.store});

  @override
  State<AddClothingPage> createState() => _AddClothingPageState();
}

class _AddClothingPageState extends State<AddClothingPage> {
  final ImagePicker _picker = ImagePicker();
  XFile? _picked;

  final TextEditingController _note = TextEditingController();

  String _category = 'TOP';
  String _color = 'Black';
  int _warmth = 2; // 1/2/3
  String _occasion = 'casual';


  final _categories = const [
    ('TOP', Icons.checkroom_rounded),
    ('BOTTOM', Icons.straighten_rounded),
    ('OUTER', Icons.layers_rounded),
    ('SHOES', Icons.directions_run_rounded),
    ('ACCESSORY', Icons.watch_rounded),
  ];

  final _colors = const ['Black', 'White', 'Gray', 'Blue', 'Red', 'Green', 'Beige'];

  final _warmths = const [
  (1, 'Thin', Icons.ac_unit_rounded),
  (2, 'Medium', Icons.thermostat_rounded),
  (3, 'Warm', Icons.local_fire_department_rounded),
];

final _occasions = const [
  ('casual', 'Casual', Icons.local_cafe_rounded),
  ('sport', 'Sport', Icons.sports_gymnastics_rounded),
  ('smart', 'Smart', Icons.work_rounded),
  ('formal', 'Formal', Icons.restaurant_rounded),
];


  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Şimdilik web değil, Android’de devam.')),
      );
      return;
    }

    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1440,
    );

    if (file == null) return;

    setState(() => _picked = file);
  }

  void _save() {
    if (_picked == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Önce foto seç.')),
      );
      return;
    }

final item = ClothingItem(
  id: DateTime.now().microsecondsSinceEpoch.toString(),
  imagePath: _picked!.path,
  category: _category,
  color: _color,
  note: _note.text.trim(),
  createdAt: DateTime.now(),
  warmth: _warmth,
  occasion: _occasion,
);


    widget.store.add(item);
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Eklendi.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const _NeonBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BackHeader(title: 'Kıyafet Ekle', onBack: () => Navigator.pop(context)),
                  const SizedBox(height: 14),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _GlassCard(
                            padding: const EdgeInsets.all(12),
                            child: AspectRatio(
                              aspectRatio: 16 / 10,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(18),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Container(color: Colors.white.withOpacity(0.06)),
                                    if (_picked == null)
                                      const Center(
                                        child: Icon(Icons.image_rounded,
                                            size: 52, color: Color(0xFFA9B3D6)),
                                      )
                                    else
                                      Image.file(
                                        File(_picked!.path),
                                        fit: BoxFit.cover,
                                      ),
                                    Positioned(
                                      right: 10,
                                      top: 10,
                                      child: _ChipButton(
                                        text: 'Seç',
                                        icon: Icons.photo_library_rounded,
                                        onTap: _pickImage,
                                      ),
                                    ),
                                    Positioned(
                                      left: 12,
                                      bottom: 12,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _picked == null ? 'Fotoğraf seç' : 'Seçildi',
                                            style: const TextStyle(
                                              color: Color(0xFFEAF0FF),
                                              fontSize: 18,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          const Text(
                                            'Galeriden yükle',
                                            style: TextStyle(
                                              color: Color(0xFFA9B3D6),
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          _GlassCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _SectionTitle('Kategori'),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: _categories.map((e) {
                                    final selected = _category == e.$1;
                                    return _SelectChip(
                                      label: e.$1,
                                      icon: e.$2,
                                      selected: selected,
                                      onTap: () => setState(() => _category = e.$1),
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 16),
                                const _SectionTitle('Renk'),
                                const SizedBox(height: 10),
                                _FakeDropdown(
                                  text: _color,
                                  onTap: () async {
                                    final picked = await showModalBottomSheet<String>(
                                      context: context,
                                      backgroundColor: const Color(0xFF0B1030),
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                                      ),
                                      builder: (_) => _ColorPickerSheet(values: _colors, current: _color),
                                    );
                                    if (picked != null) setState(() => _color = picked);
                                  },
                                ),
                                const SizedBox(height: 16),
                                const SizedBox(height: 16),
const _SectionTitle('Kalınlık'),
const SizedBox(height: 10),
Wrap(
  spacing: 10,
  runSpacing: 10,
  children: _warmths.map((e) {
    final selected = _warmth == e.$1;
    return _SelectChip(
      label: e.$2,
      icon: e.$3,
      selected: selected,
      onTap: () => setState(() => _warmth = e.$1),
    );
  }).toList(),
),

const SizedBox(height: 16),
const _SectionTitle('Ortam'),
const SizedBox(height: 10),
Wrap(
  spacing: 10,
  runSpacing: 10,
  children: _occasions.map((e) {
    final selected = _occasion == e.$1;
    return _SelectChip(
      label: e.$2,
      icon: e.$3,
      selected: selected,
      onTap: () => setState(() => _occasion = e.$1),
    );
  }).toList(),
),

                                const _SectionTitle('Not'),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _note,
                                  maxLines: 3,
                                  decoration: InputDecoration(
                                    hintText: 'örn: dar, kırmızı sevmem',
                                    hintStyle: const TextStyle(color: Color(0xFF8F9AC7)),
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
                                      borderSide: BorderSide(color: Colors.white.withOpacity(0.25)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 96),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: _PrimaryButton(
                text: 'Kaydet',
                icon: Icons.check_rounded,
                onTap: _save,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ClosetPage extends StatefulWidget {
  final OutfitStore store;
  const ClosetPage({super.key, required this.store});

  @override
  State<ClosetPage> createState() => _ClosetPageState();
}

class _ClosetPageState extends State<ClosetPage> {
  String _query = '';
  String _category = 'ALL';
  String _color = 'ALL';

  List<ClothingItem> get _filtered {
    final items = widget.store.items;

    return items.where((it) {
      final q = _query.trim().toLowerCase();
      final okQuery = q.isEmpty ||
          it.note.toLowerCase().contains(q) ||
          it.category.toLowerCase().contains(q) ||
          it.color.toLowerCase().contains(q);
          it.occasion.toLowerCase().contains(q) ||
it.warmth.toString().contains(q);


      final okCat = _category == 'ALL' || it.category == _category;
      final okColor = _color == 'ALL' || it.color == _color;
      return okQuery && okCat && okColor;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const _NeonBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BackHeader(title: 'Dolabım', onBack: () => Navigator.pop(context)),
                  const SizedBox(height: 12),

                  // SEARCH
                  _GlassCard(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: 'Ara: not, kategori, renk...',
                        hintStyle: const TextStyle(color: Color(0xFF8F9AC7)),
                        prefixIcon: const Icon(Icons.search_rounded),
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
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.25)),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // FILTERS
                  _GlassCard(
                    padding: const EdgeInsets.all(12),
                    child: Row(
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
                            values: const ['ALL', 'Black', 'White', 'Gray', 'Blue', 'Red', 'Green', 'Beige'],
                            onPick: (v) => setState(() => _color = v),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  Expanded(
                    child: AnimatedBuilder(
                      animation: widget.store,
                      builder: (context, _) {
                        final items = _filtered;

                        if (widget.store.items.isEmpty) {
                          return Center(
                            child: _GlassCard(
                              child: const Row(
                                children: [
                                  Icon(Icons.inbox_rounded, color: Color(0xFF00E5FF)),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Dolap boş. Home’dan “Kıyafet Ekle” ile başla.',
                                      style: TextStyle(color: Color(0xFFA9B3D6)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        if (items.isEmpty) {
                          return Center(
                            child: _GlassCard(
                              child: const Row(
                                children: [
                                  Icon(Icons.filter_alt_off_rounded, color: Color(0xFFFF4D8D)),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Filtre/arama sonucu boş.',
                                      style: TextStyle(color: Color(0xFFA9B3D6)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        return GridView.builder(
                          itemCount: items.length,
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.80,
                          ),
                          itemBuilder: (context, i) {
                            final item = items[i];
                            return GestureDetector(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ClothingDetailPage(store: widget.store, item: item),
                                  ),
                                );
                              },
                              onLongPress: () {
                                widget.store.removeById(item.id);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Silindi.')),
                                );
                              },
                              child: _ClosetCard(item: item),
                            );
                          },
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 6),
                  const Text(
                    'İpucu: kartı basılı tut = sil • tıkla = detay',
                    style: TextStyle(color: Color(0xFF6F7AA8)),
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


/* ---------- UI pieces ---------- */

class _TopBar extends StatelessWidget {
  final int count;
  const _TopBar({required this.count});

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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white.withOpacity(0.06),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: const Row(
            children: [
              Icon(Icons.cloud_rounded, size: 18, color: Color(0xFF00E5FF)),
              SizedBox(width: 8),
              Text('Hava', style: TextStyle(color: Color(0xFFA9B3D6))),
            ],
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
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inventory_2_rounded, size: 18, color: Color(0xFFFF4D8D)),
          const SizedBox(width: 8),
          Text('$count', style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _BackHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _BackHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: Color(0xFFEAF0FF),
          ),
        ),
      ],
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
      style: const TextStyle(
        color: Color(0xFFEAF0FF),
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _NeonBackground extends StatelessWidget {
  const _NeonBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(color: const Color(0xFF070A1A)),
        const Positioned(left: -140, top: -120, child: _GlowBlob(color: Color(0xFF7C4DFF), size: 320)),
        const Positioned(right: -160, top: 60, child: _GlowBlob(color: Color(0xFF00E5FF), size: 340)),
        const Positioned(left: 40, bottom: -180, child: _GlowBlob(color: Color(0xFFFF4D8D), size: 360)),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(color: Colors.transparent),
        ),
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
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withOpacity(0.55),
            color.withOpacity(0.10),
            Colors.transparent,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _GlassCard({required this.child, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Pill({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w800)),
        ],
      ),
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
    return SizedBox(
      height: 54,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(text, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  const _OutlineButton({required this.text, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(text, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  const _ChipButton({required this.text, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Colors.black.withOpacity(0.35),
          border: Border.all(color: Colors.white.withOpacity(0.14)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
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
  const _SelectChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? const Color(0xFF7C4DFF).withOpacity(0.28) : Colors.white.withOpacity(0.06);
    final border = selected ? const Color(0xFF7C4DFF).withOpacity(0.65) : Colors.white.withOpacity(0.10);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: bg,
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: selected ? const Color(0xFFEAF0FF) : const Color(0xFF00E5FF)),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _FakeDropdown extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _FakeDropdown({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
            const Icon(Icons.palette_rounded, color: Color(0xFF00E5FF), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
              ),
            ),
            const Icon(Icons.expand_more_rounded, color: Color(0xFFA9B3D6)),
          ],
        ),
      ),
    );
  }
}

class _ColorPickerSheet extends StatelessWidget {
  final List<String> values;
  final String current;
  const _ColorPickerSheet({required this.values, required this.current});

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.70;

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
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Renk seç',
                  style: TextStyle(color: Color(0xFFEAF0FF), fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: values.length,
                  itemBuilder: (_, i) {
                    final v = values[i];
                    final selected = v == current;
                    return ListTile(
                      onTap: () => Navigator.pop(context, v),
                      title: Text(
                        v,
                        style: const TextStyle(
                          color: Color(0xFFEAF0FF),
                          fontWeight: FontWeight.w800,
                        ),
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
  }
}


class ClothingDetailPage extends StatelessWidget {
  final OutfitStore store;
  final ClothingItem item;
  const ClothingDetailPage({super.key, required this.store, required this.item});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const _NeonBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BackHeader(title: 'Detay', onBack: () => Navigator.pop(context)),
                  const SizedBox(height: 14),
                  _GlassCard(
                    padding: const EdgeInsets.all(12),
                    child: AspectRatio(
                      aspectRatio: 16 / 10,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(color: Colors.white.withOpacity(0.06)),
                            if (item.imagePath != null)
                              Image.file(File(item.imagePath!), fit: BoxFit.cover),
                            Positioned(left: 10, top: 10, child: _MiniBadge(text: item.category)),
                            Positioned(
                              right: 10,
                              top: 10,
                              child: _MiniBadge(
                                text: item.color,
                                accent: const Color(0xFF00E5FF),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Not',
                          style: TextStyle(
                            color: Color(0xFFEAF0FF),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          item.note.isEmpty ? 'Not yok.' : item.note,
                          style: const TextStyle(color: Color(0xFFA9B3D6), height: 1.3),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Eklenme: ${item.createdAt}',
                          style: const TextStyle(color: Color(0xFF6F7AA8)),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  _PrimaryButton(
                    text: 'Sil',
                    icon: Icons.delete_rounded,
                    onTap: () {
                      store.removeById(item.id);
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Silindi.')),
                      );
                    },
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

class _FilterChipRow extends StatelessWidget {
  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onPick;

  const _FilterChipRow({
    required this.label,
    required this.value,
    required this.values,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          backgroundColor: const Color(0xFF0B1030),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
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
                          style: const TextStyle(
                            color: Color(0xFFEAF0FF),
                            fontWeight: FontWeight.w900,
                          ),
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
                                v,
                                style: const TextStyle(
                                  color: Color(0xFFEAF0FF),
                                  fontWeight: FontWeight.w800,
                                ),
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
                    value,
                    style: const TextStyle(
                      color: Color(0xFFEAF0FF),
                      fontWeight: FontWeight.w900,
                    ),
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

class _ClosetCard extends StatelessWidget {
  final ClothingItem item;
  const _ClosetCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Colors.white.withOpacity(0.06)),
                  if (item.imagePath != null)
                    Image.file(File(item.imagePath!), fit: BoxFit.cover),
                  Positioned(left: 10, top: 10, child: _MiniBadge(text: item.category)),
                  Positioned(
                    right: 10,
                    top: 10,
                    child: _MiniBadge(text: item.color, accent: const Color(0xFF00E5FF)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            item.category,
            style: const TextStyle(
              color: Color(0xFFEAF0FF),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
Text(
  '${item.occasion.toUpperCase()} • ${item.warmth == 1 ? 'THIN' : item.warmth == 2 ? 'MEDIUM' : 'WARM'}',
  style: const TextStyle(color: Color(0xFF6F7AA8), fontWeight: FontWeight.w800),
),

          Text(
            item.note.isEmpty ? '—' : item.note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFA9B3D6)),
          ),
        ],
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String text;
  final Color accent;
  const _MiniBadge({required this.text, this.accent = const Color(0xFFFF4D8D)});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.35),
            border: Border.all(color: accent.withOpacity(0.55)),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xFFEAF0FF),
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
