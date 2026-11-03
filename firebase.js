import { initializeApp } from "firebase/app";
import { getAnalytics } from "firebase/analytics";

const firebaseConfig = {
  apiKey: "AIzaSyDqrTnw_JU8kO06hH5cO3WbTDhRpN38NWE",
  authDomain: "crossfit-cainta.firebaseapp.com",
  projectId: "crossfit-cainta",
  storageBucket: "crossfit-cainta.firebasestorage.app",
  messagingSenderId: "641873687148",
  appId: "1:641873687148:web:df782fcd1b3bb6c57a1e49",
  measurementId: "G-WF67TL3JQP"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const analytics = getAnalytics(app);

// Add this line to verify connection:
console.log("Firebase successfully initialized for project:", app.options.projectId);