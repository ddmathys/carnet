import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/services/backend_client.dart';

/// Ouvre la feuille d'envoi par lien d'UN souvenir — pour quelqu'un sans
/// compte carnet (grand-parent, ami). Reprend les médias déjà présents sur
/// le souvenir, rien à réimporter (demande de David, 15.09.26, validée sur
/// maquette avant implémentation : https://claude.ai/artifact/DFpZEoARTdpyKL7bJ5poCB).
Future<void> showShareLinkSheet(BuildContext context, MemoryModel memory) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ShareLinkSheet(memory: memory),
  );
}

class ShareLinkSheet extends StatefulWidget {
  final MemoryModel memory;
  const ShareLinkSheet({super.key, required this.memory});

  @override
  State<ShareLinkSheet> createState() => _ShareLinkSheetState();
}

class _ShareLinkSheetState extends State<ShareLinkSheet> {
  final _messageCtrl = TextEditingController();
  bool _creating = false;
  String? _error;
  ({String url, DateTime expiresAt})? _link;
  String? _copyFeedback;
  Timer? _copyFeedbackTimer;

  // Mêmes règles de comptage que le backend (photoKeysOf/videoKeysOf) : ce
  // qu'on affiche ici doit correspondre à ce qui part réellement.
  int get _photoCount => widget.memory.mediaKeys.isNotEmpty
      ? widget.memory.mediaKeys.length
      : widget.memory.mediaUrls.length;
  int get _videoCount => widget.memory.videoKeys.length;

  @override
  void dispose() {
    _messageCtrl.dispose();
    _copyFeedbackTimer?.cancel();
    super.dispose();
  }

  String get _shareMessage {
    final msg = _messageCtrl.text.trim();
    return '${msg.isNotEmpty ? '$msg\n\n' : ''}'
        '📷 Un souvenir partagé sur Carnet :\n${_link!.url}';
  }

  Future<void> _createLink() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final data = await BackendClient.postJson('/api/video/share-create', {
        'memoryId': widget.memory.id,
        'message': _messageCtrl.text.trim(),
      });
      if (!mounted) return;
      final url = data?['url'] as String?;
      final expiresMs = data?['expiresAt'] as num?;
      if (url == null || expiresMs == null) {
        setState(() {
          _error = 'Création du lien impossible. Réessaie.';
          _creating = false;
        });
        return;
      }
      setState(() {
        _link = (
          url: url,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresMs.toInt()),
        );
        _creating = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Erreur : $e';
          _creating = false;
        });
      }
    }
  }

  void _flashCopied() {
    HapticFeedback.selectionClick();
    _copyFeedbackTimer?.cancel();
    setState(() => _copyFeedback = 'Lien copié ✓');
    _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copyFeedback = null);
    });
  }

  void _copyLink() {
    if (_link == null) return;
    Clipboard.setData(ClipboardData(text: _link!.url));
    _flashCopied();
  }

  Future<void> _shareLink() async {
    if (_link == null) return;
    await Share.share(_shareMessage, subject: 'Un souvenir partagé');
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.memory;
    final hasMedia = _photoCount > 0 || _videoCount > 0;
    final countsLabel = [
      if (_photoCount > 0) '$_photoCount photo${_photoCount > 1 ? 's' : ''}',
      if (_videoCount > 0) '$_videoCount vidéo${_videoCount > 1 ? 's' : ''}',
    ].join(' · ');

    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 12, 24, MediaQuery.of(context).padding.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(children: [
              const Icon(Icons.ios_share, color: AppColors.sageDark, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Envoyer par lien',
                  style: const TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            if (!hasMedia)
              const Text(
                'Ce souvenir n\'a ni photo ni vidéo — rien à envoyer par lien.',
                style: TextStyle(
                    color: AppColors.error, fontSize: 13, height: 1.4),
              )
            else ...[
              Text(
                m.title?.trim().isNotEmpty == true
                    ? '« ${m.title!.trim()} » — $countsLabel. Pour quelqu\'un '
                        'sans l\'app : il voit et télécharge les médias dans '
                        'son navigateur, sans compte.'
                    : '$countsLabel. Pour quelqu\'un sans l\'app : il voit et '
                        'télécharge les médias dans son navigateur, sans compte.',
                style: const TextStyle(
                    color: AppColors.textMedium, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              if (_link == null) ...[
                TextField(
                  controller: _messageCtrl,
                  maxLines: 2,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    hintText: 'Un petit mot ? (facultatif)',
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _creating ? null : _createLink,
                    icon: _creating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.link, size: 20),
                    label: Text(_creating ? 'Création…' : 'Créer le lien'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ] else ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(
                    _link!.url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textDark),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _shareLink,
                        icon: const Icon(Icons.share, size: 16),
                        label: const Text('Partager'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyLink,
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copier'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textMedium,
                          side: const BorderSide(color: AppColors.border),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_copyFeedback != null) ...[
                  const SizedBox(height: 10),
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle,
                            color: AppColors.sage, size: 16),
                        const SizedBox(width: 6),
                        Text(_copyFeedback!,
                            style: const TextStyle(
                                color: AppColors.sage,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  'Valide jusqu\'au ${_formatDate(_link!.expiresAt)}',
                  style: const TextStyle(
                      color: AppColors.textMedium, fontSize: 11.5),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.error_outline,
                      color: AppColors.error, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(_error!,
                          style: const TextStyle(
                              color: AppColors.error, fontSize: 12))),
                ]),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime d) {
  const mois = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];
  return '${d.day} ${mois[d.month - 1]} ${d.year}';
}
