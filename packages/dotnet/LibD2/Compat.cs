// `record struct` and init-only members need this type, and netstandard2.0 predates it.
// Declaring it here is the standard polyfill; the compiler only looks the name up, and the
// runtime never touches it.
#if !NET5_0_OR_GREATER
namespace System.Runtime.CompilerServices
{
    internal static class IsExternalInit { }
}
#endif
