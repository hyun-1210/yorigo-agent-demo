/**
 * Firebase Auth + admin_emails 게이트
 */
import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js';
import {
  getAuth,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signInWithPopup,
  GoogleAuthProvider,
  signOut,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js';
import { getFirestore, doc, getDoc } from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js';
import { firebaseConfig } from './firebase-config.js';

const app = initializeApp(firebaseConfig);
export const auth = getAuth(app);
export const db = getFirestore(app);

export async function checkIsAdmin(user) {
  if (!user) return false;
  const email = (user.email || '').trim().toLowerCase();
  if (!email) return false;
  // 앱 AdminService와 동일: emailVerified 필수
  if (user.emailVerified !== true) return false;
  const snap = await getDoc(doc(db, 'admin_emails', email));
  return snap.exists() && snap.data()?.active === true;
}

export function watchAuth(callback) {
  return onAuthStateChanged(auth, callback);
}

export async function loginEmail(email, password) {
  return signInWithEmailAndPassword(auth, email.trim(), password);
}

export async function loginGoogle() {
  const provider = new GoogleAuthProvider();
  return signInWithPopup(auth, provider);
}

export async function logout() {
  return signOut(auth);
}
