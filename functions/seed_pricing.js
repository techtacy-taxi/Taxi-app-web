// functions/seed_pricing.js
//
// ΜΙΑ ΦΟΡΑ: γεμίζει τις ζώνες + διαδρομές τιμολόγησης (pricing_zones,
// pricing_routes) με όλα όσα έχουμε συμφωνήσει μέχρι τώρα. Ασφαλές να ξανα-
// τρέξει (merge) — δεν σβήνει τίποτα, απλώς ενημερώνει τα ίδια docs.
//
// Εκτέλεση (μέσα από τον φάκελο functions/, όπου υπάρχει ήδη το
// node_modules/firebase-admin):
//
//   node seed_pricing.js
//
// Χρειάζεται credentials για το project. Αν πετάξει σφάλμα auth:
//   gcloud auth application-default login
// ή κατέβασε service account key (Firebase Console → Project Settings →
// Service accounts → Generate new private key) και:
//   set GOOGLE_APPLICATION_CREDENTIALS=C:\path\to\key.json   (PowerShell: $env:GOOGLE_APPLICATION_CREDENTIALS="...")

const admin = require("firebase-admin");
admin.initializeApp({ projectId: "my-taxi-app-bbc7c" });
const db = admin.firestore();

// ── Ζώνες (κέντρο + ακτίνα σε μέτρα) — πραγματικές συντεταγμένες τοποθεσιών.
// Άλλαξε ελεύθερα ακτίνες/κέντρα μετά, από τη σελίδα «Ζώνες & Τιμές».
const ZONES = {
  lavrio:   { name: "Λαύριο",                  lat: 37.7163, lng: 24.0586, radius: 5000 },
  athens:   { name: "Αθήνα (κέντρο)",           lat: 37.9755, lng: 23.7348, radius: 6000 },
  airport:  { name: "Αεροδρόμιο Ελ. Βενιζέλος", lat: 37.9364, lng: 23.9445, radius: 4000 },
  lagonisi: { name: "Λαγονήσι",                 lat: 37.8330, lng: 23.9330, radius: 3000 },
  koropi:   { name: "Κορωπί",                   lat: 37.9020, lng: 23.8990, radius: 3500 },
  varkiza:  { name: "Βάρκιζα",                  lat: 37.8130, lng: 23.7960, radius: 2500 },
  voula:    { name: "Βούλα",                    lat: 37.8460, lng: 23.7800, radius: 2500 },
  glyfada:  { name: "Γλυφάδα",                  lat: 37.8710, lng: 23.7530, radius: 3000 },
  piraeus:  { name: "Πειραιάς",                 lat: 37.9475, lng: 23.6350, radius: 4500 },
};

// [fromZoneId, toZoneId, taxi, van, taxiForeign?, vanForeign?]
const ROUTES = [
  ["lavrio", "athens", 88, 140],
  ["athens", "lavrio", 88, 140],

  ["lavrio", "airport", 53, 100],
  ["airport", "lavrio", 56, 100],

  ["lagonisi", "airport", 40, 82, 48],
  ["airport", "lagonisi", 45, 82, 48],

  ["lagonisi", "koropi", 28, 60, 30],
  ["koropi", "lagonisi", 28, 60, 30],

  ["lagonisi", "varkiza", 30, 60, 35, 70],
  ["varkiza", "lagonisi", 30, 60, 35, 70],

  ["lagonisi", "voula", 30, 60, 35, 70],
  ["voula", "lagonisi", 30, 60, 35, 70],

  ["lagonisi", "glyfada", 35, 70, 40, 80],
  ["glyfada", "lagonisi", 35, 70, 40, 80],

  ["lagonisi", "athens", 55, 100],
  ["athens", "lagonisi", 55, 100],

  ["lagonisi", "piraeus", 60, 110],
  ["piraeus", "lagonisi", 60, 110],
];

async function seedZones() {
  const batch = db.batch();
  for (const [id, z] of Object.entries(ZONES)) {
    batch.set(db.collection("pricing_zones").doc(id), z, { merge: true });
  }
  await batch.commit();
  console.log(`✔ ${Object.keys(ZONES).length} ζώνες.`);
}

async function seedRoutes() {
  const batch = db.batch();
  for (const [fromZoneId, toZoneId, taxi, van, taxiForeign, vanForeign] of ROUTES) {
    const id = `${fromZoneId}__${toZoneId}`;
    const data = { fromZoneId, toZoneId, taxi, van };
    if (taxiForeign != null) data.taxiForeign = taxiForeign;
    if (vanForeign != null) data.vanForeign = vanForeign;
    batch.set(db.collection("pricing_routes").doc(id), data, { merge: true });
  }
  await batch.commit();
  console.log(`✔ ${ROUTES.length} διαδρομές.`);
}

(async () => {
  await seedZones();
  await seedRoutes();
  console.log("Έτοιμο — άνοιξε «Ζώνες & Τιμές» στην εφαρμογή για να τα δεις/επεξεργαστείς.");
  process.exit(0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
