package ch.gravendev.bloom

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Partage entrant Android : « Partager » depuis Google Photos, la galerie, etc.
 *
 * L'appli déclare dans le manifeste qu'elle sait recevoir des images et des
 * vidéos (`ACTION_SEND` pour un média, `ACTION_SEND_MULTIPLE` pour plusieurs).
 * Android nous passe alors des URIs `content://` dont le droit de lecture est
 * temporaire : on les RECOPIE dans le cache de l'appli avant de rendre la main,
 * sinon les fichiers deviennent illisibles dès que l'écran de partage se ferme.
 *
 * Côté Flutter (`shared_media_service.dart`) :
 *  - `getInitialSharedMedia` : les médias du lancement (appli fermée) ;
 *  - le canal d'événements : les partages suivants (appli déjà ouverte,
 *    `launchMode="singleTop"` → `onNewIntent`).
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val METHOD_CHANNEL = "ch.gravendev.bloom/shared_media"
        private const val EVENT_CHANNEL = "ch.gravendev.bloom/shared_media_events"
        private const val CACHE_DIR = "shared_media"
        private const val LOG_TAG = "CarnetSharedMedia"
        // Doit correspondre au <category> de res/xml/shortcuts.xml : c'est ce
        // qui relie un raccourci publié à chaud au share-target du manifeste.
        private const val SHARE_CATEGORY = "ch.gravendev.bloom.category.SOUVENIR"
        private const val SHORTCUT_PREFIX = "tag_"
        // Android n'en affiche qu'une poignée ; au-delà, on encombre pour rien.
        private const val MAX_SHORTCUTS = 4
        // Les copies servent le temps de créer le souvenir : au-delà, c'est du
        // déchet (partage abandonné, appli tuée) qu'on purge au partage suivant.
        private const val MAX_AGE_MS = 24L * 60L * 60L * 1000L
    }

    // Copies de fichiers : jamais sur le thread principal (une vidéo pèse lourd).
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // URIs reçues au lancement, pas encore réclamées par Flutter.
    private var pendingUris: List<Uri> = emptyList()
    // Médias déjà copiés mais arrivés avant que Flutter n'écoute (rare).
    private val pendingItems = mutableListOf<Map<String, String>>()
    // Tag visé quand le partage est passé par un raccourci (« Ajouter à Léa »).
    private var pendingTagId: String? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Intent de lancement : on note les URIs tout de suite (aucune écriture
        // disque ici), la copie n'aura lieu que si Flutter les demande.
        pendingUris = extractUris(intent)
        pendingTagId = shortcutTagId(intent)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialSharedMedia" -> {
                        val uris = pendingUris
                        val already = pendingItems.toList()
                        val tagId = pendingTagId
                        pendingUris = emptyList()
                        pendingItems.clear()
                        pendingTagId = null
                        if (uris.isEmpty() && already.isEmpty()) {
                            result.success(payload(null, emptyList()))
                        } else {
                            ioExecutor.execute {
                                val items = already + copyToCache(uris)
                                mainHandler.post { result.success(payload(tagId, items)) }
                            }
                        }
                    }
                    // Un raccourci par tag, republié à chaque démarrage : les
                    // libellés suivent les tags de l'utilisateur.
                    "publishShareShortcuts" -> {
                        val raw = call.arguments as? List<*> ?: emptyList<Any?>()
                        val tags = raw.mapNotNull { entry ->
                            val map = entry as? Map<*, *> ?: return@mapNotNull null
                            val id = map["id"] as? String ?: return@mapNotNull null
                            val label = map["label"] as? String ?: return@mapNotNull null
                            id to label
                        }
                        result.success(publishShareShortcuts(tags))
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    /** Partage reçu alors que l'appli tourne déjà. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uris = extractUris(intent)
        if (uris.isEmpty()) return
        val tagId = shortcutTagId(intent)
        ioExecutor.execute {
            val items = copyToCache(uris)
            if (items.isEmpty()) return@execute
            mainHandler.post {
                val sink = eventSink
                if (sink != null) {
                    sink.success(payload(tagId, items))
                } else {
                    // Flutter n'écoute pas encore : le prochain
                    // `getInitialSharedMedia` les récupérera.
                    pendingItems.addAll(items)
                    pendingTagId = tagId
                }
            }
        }
    }

    /** Enveloppe commune aux deux canaux : le tag visé + les médias reçus. */
    private fun payload(tagId: String?, items: List<Map<String, String>>): Map<String, Any?> =
        mapOf("tagId" to tagId, "items" to items)

    override fun onDestroy() {
        ioExecutor.shutdown()
        super.onDestroy()
    }

    // ── Extraction des URIs de l'intent ─────────────────────────────────────

    private fun extractUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> singleStreamExtra(intent)?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE -> uris.addAll(multipleStreamExtras(intent))
            else -> return emptyList()
        }
        // Quelques applis ne renseignent que le ClipData.
        if (uris.isEmpty()) {
            val clip: ClipData? = intent.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) {
                    clip.getItemAt(i).uri?.let { uris.add(it) }
                }
            }
        }
        // L'intent reste attaché à l'activité : sans ça, une recréation de
        // l'activité rejouerait le même partage et dupliquerait les médias.
        intent.removeExtra(Intent.EXTRA_STREAM)
        return uris
    }

    @Suppress("DEPRECATION")
    private fun singleStreamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun multipleStreamExtras(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }) ?: emptyList()

    // ── Raccourcis de partage (rangée de suggestions) ───────────────────────

    /**
     * Publie un raccourci par tag (« Ajouter à Léa »), ce qui rend Carnet
     * éligible à la rangée du haut du menu de partage et permet de tomber
     * directement dans le bon tag.
     *
     * Republié à chaque démarrage : `setDynamicShortcuts` remplace la liste
     * entière, donc un tag renommé ou supprimé disparaît tout seul.
     * Retourne le nombre de raccourcis effectivement publiés.
     */
    private fun publishShareShortcuts(tags: List<Pair<String, String>>): Int {
        val limit = minOf(MAX_SHORTCUTS, ShortcutManagerCompat.getMaxShortcutCountPerActivity(this))
        if (limit <= 0) return 0
        val icon = IconCompat.createWithResource(this, R.mipmap.ic_launcher)

        val shortcuts = tags.mapNotNull { (rawId, rawLabel) ->
            val id = rawId.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val label = rawLabel.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            ShortcutInfoCompat.Builder(this, SHORTCUT_PREFIX + id)
                .setShortLabel(label)
                .setLongLabel("Ajouter à $label")
                .setIcon(icon)
                .setCategories(setOf(SHARE_CATEGORY))
                // Indispensable : sans `longLived`, Android ne garde pas le
                // raccourci comme cible de partage une fois qu'il est retiré
                // de la liste dynamique.
                .setLongLived(true)
                .setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_VIEW))
                .build()
        }.take(limit)

        return try {
            ShortcutManagerCompat.setDynamicShortcuts(this, shortcuts)
            shortcuts.size
        } catch (error: Exception) {
            // Quota constructeur dépassé, ROM capricieuse : le partage normal
            // continue de marcher, seule la rangée de suggestions y perd.
            Log.w(LOG_TAG, "Raccourcis de partage non publiés", error)
            0
        }
    }

    /**
     * Le partage est-il passé par un raccourci « Ajouter à … » ? Si oui, on
     * renvoie l'id du tag visé, qui sera pré-coché dans le formulaire.
     */
    private fun shortcutTagId(intent: Intent?): String? {
        val id = intent?.getStringExtra(ShortcutManagerCompat.EXTRA_SHORTCUT_ID) ?: return null
        if (!id.startsWith(SHORTCUT_PREFIX)) return null
        return id.removePrefix(SHORTCUT_PREFIX).takeIf { it.isNotBlank() }
    }

    // ── Copie vers le cache de l'appli ──────────────────────────────────────

    /**
     * Recopie chaque URI dans `cache/shared_media/` et renvoie, pour chacune,
     * `{path, mimeType}`. Ce qui n'est ni image ni vidéo est ignoré, et un
     * média illisible n'empêche jamais les autres de passer.
     */
    private fun copyToCache(uris: List<Uri>): List<Map<String, String>> {
        if (uris.isEmpty()) return emptyList()
        val dir = File(cacheDir, CACHE_DIR)
        if (!dir.exists()) dir.mkdirs()
        purgeOldFiles(dir)

        val items = mutableListOf<Map<String, String>>()
        uris.forEachIndexed { index, uri ->
            try {
                val mime = (contentResolver.getType(uri) ?: guessMimeType(uri)).lowercase()
                if (!mime.startsWith("image/") && !mime.startsWith("video/")) return@forEachIndexed
                val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                    ?: if (mime.startsWith("video/")) "mp4" else "jpg"
                val destination =
                    File(dir, "share_${System.currentTimeMillis()}_$index.$extension")
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(destination).use { output ->
                        input.copyTo(output, 64 * 1024)
                    }
                }
                if (destination.length() > 0L) {
                    items.add(mapOf("path" to destination.absolutePath, "mimeType" to mime))
                }
            } catch (error: Exception) {
                // Média illisible (droit expiré, fichier distant) : on passe au
                // suivant plutôt que de faire échouer tout le partage.
                Log.w(LOG_TAG, "Média partagé ignoré : $uri", error)
            }
        }
        return items
    }

    private fun guessMimeType(uri: Uri): String {
        val extension = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
            ?: return "application/octet-stream"
        return MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(extension.lowercase())
            ?: "application/octet-stream"
    }

    private fun purgeOldFiles(dir: File) {
        val limit = System.currentTimeMillis() - MAX_AGE_MS
        dir.listFiles()?.forEach { file ->
            if (file.isFile && file.lastModified() < limit) file.delete()
        }
    }
}
