package com.xraph.plugin.flutter_unity_widget

import android.app.Activity
import android.content.Intent
import android.os.Bundle

open class OverrideUnityActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }
    open fun onUnityPlayerUnloaded() {}
    override fun onLowMemory() { super.onLowMemory() }
    override fun onNewIntent(intent: Intent?) { super.onNewIntent(intent); setIntent(intent) }
    override fun onBackPressed() { super.onBackPressed() }
    override fun onWindowFocusChanged(hasFocus: Boolean) { super.onWindowFocusChanged(hasFocus) }
    override fun onPause() { super.onPause() }
    override fun onResume() { super.onResume() }
    override fun onDestroy() { super.onDestroy() }
}