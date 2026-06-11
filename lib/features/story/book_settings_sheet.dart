import 'package:flutter/material.dart';
import '../../core/models/book_settings.dart';
import '../../core/theme/app_theme.dart';

class BookSettingsSheet extends StatefulWidget {
  final BookSettings initial;
  final void Function(BookSettings settings, bool regenerate) onApply;

  const BookSettingsSheet({
    super.key,
    required this.initial,
    required this.onApply,
  });

  @override
  State<BookSettingsSheet> createState() => _BookSettingsSheetState();
}

class _BookSettingsSheetState extends State<BookSettingsSheet> {
  late BookSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Title
          const Text(
            'Paramètres du livre',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 22),

          // ── Commentaires sur les lieux ─────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: _settings.locationComments
                  ? AppColors.sage.withOpacity(0.06)
                  : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _settings.locationComments
                    ? AppColors.sage.withOpacity(0.3)
                    : Colors.grey.shade200,
                width: 1.5,
              ),
            ),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              title: const Text(
                'Commentaires sur les lieux',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: AppColors.textDark,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  _settings.locationComments
                      ? "L'IA ajoute une courte description du lieu de visite sous chaque souvenir"
                      : 'Désactivé — seules tes descriptions apparaissent',
                  style: TextStyle(
                    fontSize: 12,
                    color: _settings.locationComments
                        ? AppColors.sage.withOpacity(0.8)
                        : AppColors.textMedium,
                  ),
                ),
              ),
              value: _settings.locationComments,
              onChanged: (v) =>
                  setState(() => _settings = _settings.copyWith(locationComments: v)),
              activeColor: AppColors.sage,
            ),
          ),

          if (_settings.locationComments) ...[
            const SizedBox(height: 16),
            const _SectionLabel(label: "Style du commentaire", icon: Icons.edit_note),
            const SizedBox(height: 8),
            _OptionRow(
              options: const [
                _Option('Poétique', '', 'Ton littéraire\net lyrique'),
                _Option('Intime', '', 'Chaleureux\net personnel'),
                _Option('Factuel', '', 'Clair et\ndescriptif'),
              ],
              selectedIndex: switch (_settings.tone) {
                'intimate' => 1,
                'narrative' => 2,
                _ => 0,
              },
              onSelect: (i) => setState(() => _settings =
                  _settings.copyWith(tone: ['poetic', 'intimate', 'narrative'][i])),
            ),
          ],

          const SizedBox(height: 24),

          // ── Buttons ────────────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                widget.onApply(_settings, false);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.sage,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              child: const Text('Sauvegarder'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _Option {
  final String label;
  final String subtitle;
  final String description;
  const _Option(this.label, this.subtitle, this.description);
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionLabel({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.sage),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: AppColors.textDark,
          ),
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  final List<_Option> options;
  final int selectedIndex;
  final void Function(int) onSelect;

  const _OptionRow({
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: options.asMap().entries.map((e) {
        final i = e.key;
        final opt = e.value;
        final active = i == selectedIndex;
        return Expanded(
          child: GestureDetector(
            onTap: () => onSelect(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: EdgeInsets.only(right: i < options.length - 1 ? 8 : 0),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                color: active ? AppColors.sage.withOpacity(0.1) : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: active ? AppColors.sage : Colors.grey.shade200,
                  width: active ? 1.5 : 1,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    opt.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active ? AppColors.sage : AppColors.textDark,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    opt.description,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: active
                          ? AppColors.sage.withOpacity(0.7)
                          : AppColors.textMedium,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
