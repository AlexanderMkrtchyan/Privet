package com.privet.privet

import io.flutter.embedding.engine.FlutterEngine

/**
 * Holds the Flutter engine so [IncomingCallActivity] / [CallActionReceiver] /
 * [IncomingCallNotifier] can push Accept / Decline into the running Dart code
 * without an activity reference. Cleared when [MainActivity] is destroyed.
 */
object FlutterEngineHolder {
    @Volatile
    private var engine: FlutterEngine? = null

    fun attach(engine: FlutterEngine) {
        this.engine = engine
    }

    fun clear() {
        this.engine = null
    }

    fun get(): FlutterEngine? = engine
}
