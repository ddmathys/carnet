import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/notebook_types.dart';

class NotebookCreateTemplateScreen extends StatefulWidget {
  const NotebookCreateTemplateScreen({super.key});

  @override
  State<NotebookCreateTemplateScreen> createState() =>
      _NotebookCreateTemplateScreenState();
}

class _NotebookCreateTemplateScreenState
    extends State<NotebookCreateTemplateScreen> {
  String _selected = 'famille';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          // ── Gradient hero ────────────────────────────────────────────────
          Stack(
            children: [
              Container(
                height: 170,
                decoration: const BoxDecoration(gradient: AppColors.heroGradient),
              ),
              Positioned(
                top: -50, right: -50,
                child: Container(
                  width: 180, height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.07), width: 1.5),
                  ),
                ),
              ),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => context.pop(),
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Nouveau carnet',
                        style: TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Choisis le type qui correspond à ton histoire.',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.72),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // ── Type list ────────────────────────────────────────────────────
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              itemCount: kNotebookTypes.length,
              itemBuilder: (_, i) {
                final type = kNotebookTypes[i];
                final selected = _selected == type.id;
                return GestureDetector(
                  onTap: () => setState(() => _selected = type.id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.sageDark.withOpacity(0.06)
                          : AppColors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected ? AppColors.sageDark : AppColors.border,
                        width: selected ? 2 : 0.5,
                      ),
                      boxShadow: selected
                          ? [BoxShadow(
                              color: AppColors.sageDark.withOpacity(0.1),
                              blurRadius: 12, offset: const Offset(0, 3))]
                          : null,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Emoji circle
                          Container(
                            width: 52, height: 52,
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.sageDark.withOpacity(0.1)
                                  : AppColors.background,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: Text(type.emoji,
                                  style: const TextStyle(fontSize: 26)),
                            ),
                          ),
                          const SizedBox(width: 14),
                          // Text
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  type.label,
                                  style: TextStyle(
                                    fontFamily: 'PlayfairDisplay',
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                    color: selected
                                        ? AppColors.sageDark
                                        : AppColors.textDark,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  type.description,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textMedium,
                                    height: 1.4,
                                  ),
                                ),
                                // "Pourquoi ce type" — only when selected
                                if (selected) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: AppColors.sageDark.withOpacity(0.07),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.info_outline,
                                          size: 14,
                                          color: AppColors.sageDark.withOpacity(0.8)),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            type.whyThis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.sageDark.withOpacity(0.85),
                                              height: 1.4,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Radio indicator
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 22, height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected ? AppColors.sageDark : Colors.transparent,
                              border: Border.all(
                                color: selected ? AppColors.sageDark : AppColors.border,
                                width: 2,
                              ),
                            ),
                            child: selected
                                ? const Icon(Icons.check, size: 13, color: Colors.white)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // ── CTA ──────────────────────────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, MediaQuery.of(context).padding.bottom + 20),
            child: ElevatedButton(
              onPressed: () =>
                  context.push('/notebook/create/config?type=$_selected'),
              child: Text(
                'Créer un carnet ${kNotebookTypes.firstWhere((t) => t.id == _selected).label.toLowerCase()}',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
