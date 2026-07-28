import 'gpu_capability_stub.dart'
    if (dart.library.io) 'gpu_capability_io.dart' as impl;

/// One-shot: is this machine capable of full UI motion (emoji, sheets, etc.)?
///
/// Capable = discrete/accelerated GPU (NVIDIA / AMD / Apple / modern Intel).
/// Weak = software rasterizers (llvmpipe, softpipe, SwiftShader) or unknown
/// with very little RAM. Web always returns capable (browser owns the GPU).
Future<bool> hasCapableGpu() => impl.hasCapableGpu();
