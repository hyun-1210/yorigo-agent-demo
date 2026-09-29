// Firebase Cloud Messaging — required for web (flutter run -d chrome, production hosting).
// Keep config in sync with lib/firebase_options.dart → DefaultFirebaseOptions.web
//
// SDK version: compat bundle; bump minor if you see version skew with firebase_core.
importScripts('https://www.gstatic.com/firebasejs/11.0.2/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/11.0.2/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyBrl8YeW-Sa7Bst1kIuHNpOAKWb8jyYSGg',
  authDomain: 'yorigo-f7408.firebaseapp.com',
  projectId: 'yorigo-f7408',
  storageBucket: 'yorigo-f7408.firebasestorage.app',
  messagingSenderId: '784944328733',
  appId: '1:784944328733:web:61d997c5826580ee8c96f4',
  measurementId: 'G-2FLEYSX21L',
});

firebase.messaging();
