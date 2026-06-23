const PDFDocument = require("pdfkit");
const fs = require("fs");

// Palette « carnet / Éclosion »
const SAGE = "#3A6648";
const CREAM = "#F5ECE0";
const WHITE = "#FFFFFF";
const DARK = "#2D2D2D";
const SOFT = "#7A6A5A";
const TERRA = "#C97B5A";
const CARD = "#FFFFFF";

const W = 960, H = 540, M = 54;
const out = "C:/develop/projects/Bloom/docs/Carnet-fonctionnement.pdf";

const doc = new PDFDocument({ size: [W, H], margin: 0 });
doc.pipe(fs.createWriteStream(out));

let first = true;
function newSlide(bg = CREAM) {
  if (!first) doc.addPage({ size: [W, H], margin: 0 });
  first = false;
  doc.rect(0, 0, W, H).fill(bg);
}

function header(kicker, title) {
  doc.rect(0, 0, W, 96).fill(SAGE);
  doc.fillColor("#CDB89C").fontSize(12).font("Helvetica-Bold")
    .text(kicker.toUpperCase(), M, 26, { characterSpacing: 2 });
  doc.fillColor(WHITE).fontSize(28).font("Helvetica-Bold")
    .text(title, M, 46, { width: W - 2 * M });
}

// Bloc « carte » avec titre coloré + lignes à puces
function card(x, y, w, h, accent, title, lines) {
  doc.roundedRect(x, y, w, h, 12).fill(CARD);
  doc.roundedRect(x, y, 6, h, 3).fill(accent);
  doc.fillColor(accent).font("Helvetica-Bold").fontSize(14)
    .text(title, x + 20, y + 16, { width: w - 36 });
  let cy = y + 42;
  doc.font("Helvetica").fontSize(11).fillColor(DARK);
  for (const ln of lines) {
    doc.circle(x + 24, cy + 6, 2).fill(accent);
    doc.fillColor(DARK).text(ln, x + 34, cy, { width: w - 52 });
    cy = doc.y + 6;
  }
}

// Rangée de « pastilles » dépendances
function chips(x, y, w, label, items, accent) {
  doc.fillColor(SOFT).font("Helvetica-Bold").fontSize(11)
    .text(label, x, y);
  let cx = x, cy = y + 18;
  doc.font("Helvetica").fontSize(10);
  for (const it of items) {
    const tw = doc.widthOfString(it) + 18;
    if (cx + tw > x + w) { cx = x; cy += 26; }
    doc.roundedRect(cx, cy, tw, 19, 9).fill("#EFE6D8");
    doc.fillColor(accent || SAGE).text(it, cx + 9, cy + 5);
    cx += tw + 8;
  }
  return cy + 28;
}

function box(x, y, w, h, fill, line1, line2, txtColor) {
  doc.roundedRect(x, y, w, h, 10).fill(fill);
  doc.fillColor(txtColor || WHITE).font("Helvetica-Bold").fontSize(12)
    .text(line1, x + 8, y + h / 2 - (line2 ? 15 : 7), { width: w - 16, align: "center" });
  if (line2) doc.font("Helvetica").fontSize(8.5)
    .text(line2, x + 8, y + h / 2 + 2, { width: w - 16, align: "center" });
}

function arrow(x1, y1, x2, y2, color) {
  doc.save().moveTo(x1, y1).lineTo(x2, y2).lineWidth(1.4).stroke(color || SOFT);
  const a = Math.atan2(y2 - y1, x2 - x1), s = 6;
  doc.moveTo(x2, y2)
    .lineTo(x2 - s * Math.cos(a - 0.4), y2 - s * Math.sin(a - 0.4))
    .lineTo(x2 - s * Math.cos(a + 0.4), y2 - s * Math.sin(a + 0.4))
    .fill(color || SOFT);
  doc.restore();
}

// ───────────────────────── 1. COUVERTURE ─────────────────────────
newSlide(SAGE);
doc.fillColor("#CDB89C").font("Helvetica-Bold").fontSize(14)
  .text("CARNET DE SOUVENIRS", M, 150, { characterSpacing: 3 });
doc.fillColor(WHITE).font("Helvetica-Bold").fontSize(64).text("Carnet", M, 178);
doc.fillColor("#E9DEC9").font("Helvetica").fontSize(20)
  .text("Comment fonctionne l'application", M, 262);
doc.fillColor("#BBA98C").fontSize(13)
  .text("Marché · Photos · Texte & commentaires · Revue IA · Vidéo · Audio · Le livre", M, 300);
doc.fillColor("#BBA98C").fontSize(13)
  .text("Étude de marché, architecture, flux et dépendances", M, 322);
doc.roundedRect(M, 380, 220, 2, 1).fill(TERRA);
doc.fillColor("#9FB6A3").fontSize(11)
  .text("Flutter · Firebase · Cloudflare R2 · Vercel · DeepSeek · Gelato", M, 400);

// ───────────────────── ÉTUDE DE MARCHÉ (1) — MODÈLE ───────────────
newSlide();
header("Étude de marché", "Modèle économique — freemium");
doc.fillColor(SOFT).font("Helvetica-Oblique").fontSize(11)
  .text("L'application est gratuite ; le bel objet (le livre) se paie. La valeur se monétise quand l'émotion est la plus forte.", M, 110, { width: W - 2 * M });
const tiers = [
  ["Découverte — Gratuit", SAGE, [
    "1 carnet actif, famille illimitée",
    "Photos, texte, mémo vocal",
    "Vidéo : 3 clips courts (≤ 30 s)",
    "Narration IA : 1 essai / carnet",
  ]],
  ["Le livre — dès CHF 49 (à l'acte)", "#B3563F", [
    "PDF prêt à imprimer (Gelato)",
    "QR Regarder / Écouter inclus",
    "Vidéos garanties 5 ans",
    "Impression + livraison · TWINT",
  ]],
  ["Carnet+ — CHF 4.90/mois · 39/an", "#7A5BA6", [
    "Carnets & vidéos illimités (HD)",
    "Hébergement garanti 10 ans",
    "Re-téléchargement à vie",
    "−10 % sur chaque livre",
  ]],
];
let tx = M;
const tw3 = (W - 2 * M - 2 * 14) / 3;
for (const [t, c, lines] of tiers) { card(tx, 150, tw3, 188, c, t, lines); tx += tw3 + 14; }
card(M, 352, W - 2 * M, 92, TERRA, "L'économie d'un livre", [
  "Production Gelato (~24–40 p.) ≈ CHF 20–22  ·  Vente conseillée CHF 49  ·  Marge brute ≈ CHF 27 (~55 %).",
  "Coût à surveiller : la vidéo (hébergement R2 récurrent) → d'où les plafonds en gratuit, libérés par le livre / Carnet+.",
]);

// ───────────────────── ÉTUDE DE MARCHÉ (2) — POSITION ─────────────
newSlide();
header("Étude de marché", "Le marché & le positionnement");
card(M, 110, W - 2 * M, 80, SAGE, "Positionnement", [
  "Le seul carnet de souvenirs pensé CH romande / France réunissant : vidéo & audio natifs et protégés (buckets privés,",
  "liens signés, RGPD/LPD), narration enrichie par l'IA, et un bel objet imprimé vendu à l'unité (pas d'abonnement subi).",
]);
const comp = [
  ["Carnet", "Livre-souvenir + médias · vidéo/audio privés · IA · CH/FR · livre 49.-"],
  ["Famileo", "Gazette récurrente · pas de vidéo/audio · abo 6–18 €/mois · FR/EU"],
  ["Storyworth", "Mémoire annuelle · vidéo partielle · abo 59–199 $/an · US"],
  ["Meminto", "Livre thématique · vidéo/audio via QR · one-time 99–149 $ · DE/EU"],
  ["CEWE / ifolor", "Livre photo · pas d'app collaborative · livre 10–60.- · CH/EU"],
];
let cy2 = 206;
for (let i = 0; i < comp.length; i++) {
  const [a, b] = comp[i];
  doc.roundedRect(M, cy2, W - 2 * M, 40, 8).fill(i === 0 ? "#E7EFE8" : (i % 2 ? "#EFE6D8" : WHITE));
  doc.fillColor(i === 0 ? SAGE : DARK).font("Helvetica-Bold").fontSize(12).text(a, M + 16, cy2 + 13, { width: 150 });
  doc.fillColor(DARK).font("Helvetica").fontSize(10.5).text(b, M + 175, cy2 + 14, { width: W - 175 - 2 * M });
  cy2 += 46;
}

// ───────────────────── ÉTUDE DE MARCHÉ (3) — ATOUTS ───────────────
newSlide();
header("Étude de marché", "Différenciateurs, risques & angles");
card(M, 110, (W - 2 * M - 14) / 2, 188, SAGE, "Nos différenciateurs", [
  "Vidéo + audio natifs et privés (les autres bricolent avec YouTube/Vimeo public).",
  "Narration IA qui écrit l'histoire du carnet — unique sur ce marché.",
  "Ancrage suisse : TWINT, données en Europe, conformité LPD/RGPD.",
  "Objet vendu à l'unité — pas d'abonnement imposé.",
]);
card(M + (W - 2 * M - 14) / 2 + 14, 110, (W - 2 * M - 14) / 2, 188, "#B3563F", "Risques & réponses", [
  "Longévité des QR → garantie d'hébergement (5–10 ans) + re-téléchargement.",
  "Incumbents (CEWE) ajoutent la vidéo → se battre sur collaboration, IA, confidentialité.",
  "Coût vidéo qui dérape → plafonds gratuit, packs / abo.",
  "Distribution solo → build-in-public + niches à fort affect.",
]);
card(M, 312, W - 2 * M, 92, "#7A5BA6", "Les angles d'attaque", [
  "Viser les moments à forte charge émotionnelle où la vidéo et la voix font la différence :",
  "naissance & 1re année · mariage · hommage / mémorial · grands voyages.",
  "Levier B2B (validé par Famileo) : résidences seniors / EHPAD et associations de parents, en licence.",
]);

// ───────────────────────── 2. VUE D'ENSEMBLE ─────────────────────
newSlide();
header("Vue d'ensemble", "Les acteurs et qui fait quoi");

// Tier 1 — l'app
box(380, 116, 200, 54, SAGE, "Application Carnet", "Flutter — iOS / Android");
// Tier 2 — le portier
box(360, 214, 240, 56, TERRA, "Vercel — le « portier »", "secrets · autorisations · URLs signées · pages web");
// Tier 3 — services
const ty = 340, bw = 138, gap = 14;
const svc = [
  ["Firebase Auth", "comptes / connexion", SAGE],
  ["Firestore", "base de données", SAGE],
  ["Firebase Storage", "photos · audio", SAGE],
  ["Cloudflare R2", "vidéos", "#4B7DB3"],
  ["DeepSeek", "IA (deepseek-chat)", "#7A5BA6"],
  ["Gelato", "impression · livraison", "#B3563F"],
];
let sx = M;
for (const [t, s, c] of svc) {
  box(sx, ty, bw, 60, WHITE, t, s, DARK);
  doc.roundedRect(sx, ty, bw, 4, 2).fill(c);
  sx += bw + gap;
}
// flèches
arrow(480, 170, 480, 214, SOFT);
arrow(470, 270, 360, 338, SOFT);
arrow(480, 270, 480, 338, SOFT);
arrow(495, 270, 760, 338, SOFT);
doc.fillColor(SOFT).font("Helvetica-Oblique").fontSize(10)
  .text("L'app passe par Vercel pour tout ce qui touche aux secrets et aux droits ; elle parle aussi directement à Firebase (connexion, base, photos) via le SDK officiel.",
    M, 430, { width: W - 2 * M });

// ───────────────────────── 3. PARCOURS GLOBAL ────────────────────
newSlide();
header("Le principe", "Le parcours d'un souvenir");
const steps = [
  ["1 · Créer", "On ouvre un carnet et on ajoute un souvenir : texte, photos, vidéo, mémo vocal."],
  ["2 · Stocker", "Texte → Firestore. Photos & audio → Firebase Storage. Vidéos → Cloudflare R2."],
  ["3 · Enrichir (IA)", "DeepSeek (via Vercel) enrichit les légendes et rédige l'histoire du carnet."],
  ["4 · Partager", "On invite la famille (collaborateurs / e-mail). Chacun voit les souvenirs s'il est membre."],
  ["5 · Imprimer", "On génère le livre photo (PDF), on paie, Gelato l'imprime et le livre à domicile."],
];
let yy = 120;
for (const [t, d] of steps) {
  card(M, yy, W - 2 * M, 64, t.startsWith("3") ? "#7A5BA6" : SAGE, t, [d]);
  yy += 76;
}

// ───────────────────────── 4. PHOTOS ─────────────────────────────
newSlide();
header("Section 1", "Ajout de photos");
card(M, 120, 392, 180, SAGE, "Côté utilisateur", [
  "Ajoute des photos depuis l'appareil ou la galerie.",
  "Légende chaque photo (lieu, date détectés tout seuls).",
  "Les voit en grille, et en grand au toucher.",
]);
card(478, 120, W - 478 - M, 180, TERRA, "En coulisses", [
  "Compression JPEG (~2048 px) sur le téléphone.",
  "Envoi vers Firebase Storage (photos/uid/carnet/…).",
  "L'adresse de la photo est notée dans le souvenir (Firestore).",
  "Affichage rapide grâce au cache d'images.",
]);
chips(M, 322, W - 2 * M, "Dépendances", [
  "image_picker", "flutter_image_compress", "cached_network_image", "exif (date/lieu)",
  "google_mlkit_text_recognition (OCR)", "firebase_storage", "cloud_firestore",
], SAGE);

// ───────────────────────── 5. TEXTE & COMMENTAIRES ───────────────
newSlide();
header("Section 2", "Texte & commentaires");
card(M, 120, 392, 180, SAGE, "Côté utilisateur", [
  "Écrit le récit du souvenir, ou un commentaire.",
  "Peut DICTER à la voix au lieu de taper.",
  "Renseigne lieu, date, type d'étape (jalon).",
]);
card(478, 120, W - 478 - M, 180, TERRA, "En coulisses", [
  "Le texte est enregistré dans Firestore (collection « memories »).",
  "La dictée : reconnaissance vocale exécutée sur l'appareil,",
  "convertie en texte, puis insérée dans le champ.",
  "Tout se synchronise en temps réel pour les membres du carnet.",
]);
chips(M, 322, W - 2 * M, "Dépendances", [
  "speech_to_text (dictée)", "cloud_firestore", "intl (dates)",
], SAGE);

// ───────────────────────── 6. REVUE IA ───────────────────────────
newSlide();
header("Section 3", "Revue & narration par l'IA");
card(M, 120, 392, 190, "#7A5BA6", "Côté utilisateur", [
  "Demande à l'IA d'enrichir les légendes des photos.",
  "Génère automatiquement « l'histoire » du carnet.",
  "Analyse de la croissance / extraction des jalons.",
]);
card(478, 120, W - 478 - M, 190, TERRA, "En coulisses", [
  "L'app n'a JAMAIS la clé de l'IA.",
  "Elle appelle le backend Vercel : /api/ai/chat.",
  "Vercel relaie la demande à DeepSeek (modèle deepseek-chat),",
  "avec sa clé secrète, puis renvoie la réponse à l'app.",
  "Fonctions : enrichir légendes, rédiger le livre, jalons, croissance.",
]);
chips(M, 332, W - 2 * M, "Dépendances / services", [
  "DeepSeekService (app)", "Vercel /api/ai/chat", "DeepSeek API (deepseek-chat)", "http",
], "#7A5BA6");

// ───────────────────────── 7. VIDÉO ──────────────────────────────
newSlide();
header("Section 4", "Ajout & lecture de vidéo");
card(M, 120, 392, 196, SAGE, "Côté utilisateur", [
  "Filme un clip (60 s max), le revoit dans l'app.",
  "Dans le livre, un QR code « Regarder » mène à la vidéo.",
  "Seuls les membres du carnet peuvent la voir.",
]);
card(478, 120, W - 478 - M, 196, "#4B7DB3", "En coulisses", [
  "Compression 720p sur le téléphone.",
  "Vercel signe une URL d'envoi → upload DIRECT vers Cloudflare R2.",
  "On ne stocke que la « clé » du fichier (pas d'URL publique).",
  "Lecture : Vercel vérifie l'appartenance au carnet,",
  "puis délivre une URL signée valable 1 h. Bucket R2 privé.",
]);
chips(M, 338, W - 2 * M, "Dépendances / services", [
  "video_compress", "video_player", "Vercel /api/video/*", "Cloudflare R2 (@aws-sdk)", "firebase_auth",
], "#4B7DB3");

// ───────────────────────── 8. AUDIO ──────────────────────────────
newSlide();
header("Section 5", "Mémo vocal (audio)");
card(M, 120, 392, 180, SAGE, "Côté utilisateur", [
  "Enregistre un message vocal pour le souvenir.",
  "Le réécoute avant de valider.",
  "Dans le livre, un QR « Écouter » lit le mémo.",
]);
card(478, 120, W - 478 - M, 180, TERRA, "En coulisses", [
  "Enregistrement au format AAC sur l'appareil.",
  "Envoi vers Firebase Storage (audio/uid/carnet/…).",
  "L'adresse est notée dans le souvenir (Firestore).",
  "Page web /listen (servie par Vercel) pour le QR.",
]);
chips(M, 322, W - 2 * M, "Dépendances", [
  "record (enregistrement)", "audioplayers (lecture)", "path_provider", "firebase_storage", "Vercel /listen",
], SAGE);

// ───────────────── SUIVI DE CROISSANCE (ENFANT) ──────────────────
newSlide();
header("Section 6", "Suivi de croissance (enfant)");
card(M, 120, 392, 196, SAGE, "Côté utilisateur", [
  "Carnet enfant : suit la taille et le poids dans le temps.",
  "Courbe comparée aux références OMS (P3 · P50 · P97).",
  "Toise visuelle illustrée avec l'animal compagnon.",
  "Saisie en langage libre — l'IA extrait taille & poids.",
]);
card(478, 120, W - 478 - M, 196, TERRA, "En coulisses", [
  "Mesures = souvenirs « taille_poids » (taille / poids / date).",
  "Référentiel OMS 2006 selon le sexe de l'enfant.",
  "Date de naissance du carnet → âge en mois sur l'axe.",
  "Réservé au carnet enfant (pas de courbe OMS ailleurs).",
]);
chips(M, 338, W - 2 * M, "Dépendances / services", [
  "fl_chart (courbe)", "flutter_svg (toise / animal)", "DeepSeek (extraction)", "cloud_firestore",
], SAGE);

// ───────────────────────── LE LIVRE ──────────────────────────────
newSlide();
header("Section 7", "Le livre photo imprimé");
card(M, 120, 392, 200, "#B3563F", "Côté utilisateur", [
  "Choisit un carnet et génère son livre photo.",
  "Valide la commande (aucun paiement en ligne).",
  "Reçoit le livre imprimé directement à la maison.",
  "Paie après réception, par TWINT (détails par e-mail).",
]);
card(478, 120, W - 478 - M, 200, TERRA, "En coulisses", [
  "L'app fabrique un PDF « prêt pour l'impression »",
  "(format Gelato 21×28 cm + fond perdu, QR Regarder/Écouter).",
  "MVP : facture TWINT après livraison (pas de paiement en ligne).",
  "Commande transmise à Gelato (impression + livraison).",
  "E-mails (confirmation + détails de paiement) via Resend.",
]);
chips(M, 342, W - 2 * M, "Dépendances / services", [
  "pdf", "printing", "Gelato (impression)", "Facture TWINT", "Resend (e-mails)",
], "#B3563F");

// ───────────────────────── 10. SÉCURITÉ ──────────────────────────
newSlide();
header("Transversal", "Qui a le droit de voir quoi");
card(M, 120, W - 2 * M, 96, SAGE, "Le principe unique", [
  "On voit les médias d'un carnet si on en est MEMBRE :",
  "propriétaire, collaborateur (sharedWith) ou invité par e-mail.",
]);
card(M, 232, 392, 150, "#4B7DB3", "Vidéos — verrouillées", [
  "Bucket Cloudflare R2 PRIVÉ.",
  "Accès uniquement via URL signée 1 h délivrée par Vercel,",
  "après vérification de l'appartenance au carnet.",
]);
card(478, 232, W - 478 - M, 150, TERRA, "Photos — à sécuriser", [
  "Aujourd'hui encore accessibles via un lien « token » permanent.",
  "Prochaine étape : même système signé que les vidéos",
  "(Storage privé + URL signées via Vercel).",
]);

// ───────────────────────── 11. RÉCAP STACK ───────────────────────
newSlide();
header("Récapitulatif", "La pile technique en un coup d'œil");
const rows = [
  ["Application", "Flutter (Dart) · go_router · flutter_riverpod"],
  ["Comptes", "Firebase Auth · google_sign_in"],
  ["Base de données", "Cloud Firestore (carnets, souvenirs)"],
  ["Photos / Audio", "Firebase Storage · image_picker · record · audioplayers"],
  ["Vidéos", "Cloudflare R2 · video_compress · video_player"],
  ["Backend / portier", "Vercel (fonctions serverless TypeScript)"],
  ["Intelligence artificielle", "DeepSeek (deepseek-chat) via /api/ai/chat"],
  ["Le livre", "pdf · printing · Gelato · facture TWINT · Resend"],
  ["Partage / invitations", "app_links (deep links) · share_plus"],
];
let ry = 120;
for (let i = 0; i < rows.length; i++) {
  const [a, b] = rows[i];
  doc.roundedRect(M, ry, W - 2 * M, 38, 8).fill(i % 2 ? "#EFE6D8" : WHITE);
  doc.fillColor(SAGE).font("Helvetica-Bold").fontSize(12).text(a, M + 16, ry + 12, { width: 230 });
  doc.fillColor(DARK).font("Helvetica").fontSize(11).text(b, M + 250, ry + 12, { width: W - 250 - 2 * M });
  ry += 44;
}

doc.end();
console.log("OK ->", out);
