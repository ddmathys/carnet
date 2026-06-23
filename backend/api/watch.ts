import type { VercelRequest, VercelResponse } from '@vercel/node'
import { escapeHtml } from '../lib/verify'
import { projectId } from '../lib/firebase'

// Page publique de lecture des vidéos d'un souvenir — cible des QR codes
// imprimés dans le livre. DÉSORMAIS AUTHENTIFIÉE : le bucket R2 est privé, donc
// on n'expose plus d'URL publique. Le visiteur se connecte (compte carnet), puis
// la page appelle `/api/video/play` qui ne renvoie des URLs signées que s'il est
// membre du carnet (propriétaire, collaborateur, ou invité par email). Un seul
// QR par souvenir → toutes ses vidéos.
//
// La config Firebase WEB est injectée depuis l'env (FIREBASE_WEB_API_KEY) — la
// clé API web n'est pas un secret (restreinte par domaine côté Firebase).
export default function handler(req: VercelRequest, res: VercelResponse) {
  const m = (req.query.m ?? '') as string
  res.setHeader('Content-Type', 'text/html; charset=utf-8')
  res.setHeader('Cache-Control', 'no-store')

  if (!m || typeof m !== 'string') {
    return res.status(400).send(page('Lien invalide', '<p>Identifiant manquant.</p>'))
  }

  const apiKey = process.env.FIREBASE_WEB_API_KEY ?? ''
  if (!apiKey || !projectId) {
    return res
      .status(500)
      .send(page('Configuration manquante', '<p>La lecture n’est pas encore configurée.</p>'))
  }

  const appId = process.env.FIREBASE_WEB_APP_ID ?? ''
  const cfg = forScript({
    apiKey,
    authDomain: `${projectId}.firebaseapp.com`,
    projectId,
    ...(appId ? { appId } : {}),
  })
  const memoryId = forScript(m)

  return res.status(200).send(appPage(cfg, memoryId))
}

// JSON sûr à injecter dans une balise <script> (évite la sortie de contexte).
function forScript(value: unknown): string {
  return JSON.stringify(value).replace(/</g, '\\u003c')
}

function appPage(cfgJson: string, memoryIdJson: string): string {
  return `<!DOCTYPE html><html lang="fr"><head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Vidéo souvenir · carnet</title>
${styleTag()}
</head>
<body><div class="card">
  <div class="brand">carnet</div>
  <div id="status" class="sub">Chargement…</div>

  <div id="login" style="display:none">
    <p class="lead">Connecte-toi pour voir cette vidéo souvenir.</p>
    <button id="google" class="btn btn-google">Continuer avec Google</button>
    <div class="sep">ou</div>
    <input id="email" type="email" placeholder="Adresse e-mail" autocomplete="email"/>
    <input id="pass" type="password" placeholder="Mot de passe" autocomplete="current-password"/>
    <button id="signin" class="btn">Se connecter</button>
    <button id="signup" class="btn btn-ghost">Créer un compte</button>
    <div id="err" class="err"></div>
  </div>

  <div id="userbar" style="display:none">
    <span id="who"></span>
    <button id="logout" class="link">Se déconnecter</button>
  </div>

  <div id="player"></div>
</div>

<script type="module">
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.0/firebase-app.js";
import {
  getAuth, onAuthStateChanged, signOut,
  GoogleAuthProvider, signInWithPopup,
  signInWithEmailAndPassword, createUserWithEmailAndPassword
} from "https://www.gstatic.com/firebasejs/10.12.0/firebase-auth.js";

const cfg = ${cfgJson};
const memoryId = ${memoryIdJson};
const app = initializeApp(cfg);
const auth = getAuth(app);

const $ = (id) => document.getElementById(id);
const statusEl = $("status"), loginEl = $("login"), userbar = $("userbar"),
      playerEl = $("player"), errEl = $("err");

function show(el, on) { el.style.display = on ? "" : "none"; }
function setStatus(t) { statusEl.textContent = t || ""; show(statusEl, !!t); }
function setErr(t) { errEl.textContent = t || ""; }

onAuthStateChanged(auth, async (user) => {
  setErr("");
  if (!user) {
    show(loginEl, true); show(userbar, false); playerEl.innerHTML = "";
    setStatus("");
    return;
  }
  show(loginEl, false); show(userbar, true);
  $("who").textContent = user.email || "Connecté";
  await loadVideos(user);
});

async function loadVideos(user) {
  setStatus("Chargement de la vidéo…");
  playerEl.innerHTML = "";
  try {
    const token = await user.getIdToken();
    const r = await fetch("/api/video/play", {
      method: "POST",
      headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify({ memoryId })
    });
    if (r.status === 403) {
      setStatus("Tu n’as pas accès à ce souvenir. Connecte-toi avec le compte invité à ce carnet.");
      return;
    }
    if (!r.ok) { setStatus("Impossible de charger la vidéo pour le moment."); return; }
    const data = await r.json();
    const urls = Array.isArray(data.urls) ? data.urls : [];
    if (urls.length === 0) { setStatus("Aucune vidéo pour ce souvenir."); return; }
    setStatus("");
    for (const u of urls) {
      const v = document.createElement("video");
      v.controls = true; v.playsInline = true; v.preload = "metadata"; v.src = u;
      playerEl.appendChild(v);
    }
  } catch (e) {
    setStatus("Erreur réseau. Réessaie.");
  }
}

$("google").addEventListener("click", async () => {
  setErr("");
  try { await signInWithPopup(auth, new GoogleAuthProvider()); }
  catch (e) { setErr(humanError(e)); }
});
$("signin").addEventListener("click", async () => {
  setErr("");
  try { await signInWithEmailAndPassword(auth, $("email").value.trim(), $("pass").value); }
  catch (e) { setErr(humanError(e)); }
});
$("signup").addEventListener("click", async () => {
  setErr("");
  try { await createUserWithEmailAndPassword(auth, $("email").value.trim(), $("pass").value); }
  catch (e) { setErr(humanError(e)); }
});
$("logout").addEventListener("click", () => signOut(auth));

function humanError(e) {
  const c = (e && e.code) || "";
  if (c.includes("wrong-password") || c.includes("invalid-credential")) return "E-mail ou mot de passe incorrect.";
  if (c.includes("email-already-in-use")) return "Un compte existe déjà avec cet e-mail — connecte-toi.";
  if (c.includes("weak-password")) return "Mot de passe trop court (6 caractères min).";
  if (c.includes("invalid-email")) return "Adresse e-mail invalide.";
  if (c.includes("popup-closed")) return "Connexion annulée.";
  return "Échec de la connexion. Réessaie.";
}
</script>
</body></html>`
}

function styleTag(): string {
  return `<style>
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:#f5ece0;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;padding:24px;}
  .card{background:#fff;border-radius:20px;box-shadow:0 4px 24px rgba(0,0,0,.08);
    padding:32px 28px;max-width:460px;width:100%;text-align:center;}
  .brand{color:#3A6648;font-style:italic;font-weight:bold;font-size:20px;margin-bottom:16px;}
  .sub{color:#b0a090;text-transform:uppercase;letter-spacing:1px;font-size:12px;margin:0 0 16px;}
  .lead{color:#5a4a3a;margin:0 0 18px;}
  input{width:100%;padding:12px 14px;margin:6px 0;border:1px solid #ddd6c8;border-radius:10px;font-size:15px;}
  .btn{width:100%;padding:12px 14px;margin:6px 0;border:0;border-radius:10px;font-size:15px;
    font-weight:600;cursor:pointer;background:#3A6648;color:#fff;}
  .btn-google{background:#fff;color:#3a3a3a;border:1px solid #ddd6c8;}
  .btn-ghost{background:transparent;color:#3A6648;border:1px solid #3A6648;}
  .sep{color:#b0a090;font-size:12px;margin:10px 0;}
  .err{color:#b3261e;font-size:13px;min-height:18px;margin-top:6px;}
  #userbar{display:flex;justify-content:space-between;align-items:center;font-size:13px;color:#7a6a5a;margin-bottom:14px;}
  .link{background:none;border:0;color:#3A6648;cursor:pointer;font-size:13px;text-decoration:underline;}
  video{width:100%;border-radius:12px;margin-top:10px;background:#000;}
  p{color:#7a6a5a;}
</style>`
}

// Page minimale (erreurs / états sans app).
function page(titleText: string, body: string): string {
  return `<!DOCTYPE html><html lang="fr"><head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${escapeHtml(titleText)} · carnet</title>
${styleTag()}
</head>
<body><div class="card"><div class="brand">carnet</div>${body}</div></body></html>`
}
