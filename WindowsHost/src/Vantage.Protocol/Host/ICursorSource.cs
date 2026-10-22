using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// The system pointer's look and visibility, for clients that draw the pointer themselves
/// (<c>features.localCursor</c>). Such a client moves its own pointer the moment the mouse moves,
/// the way Remote Desktop does, instead of waiting for the pointer to come back in the video.
/// </summary>
public interface ICursorSource
{
    /// <summary>
    /// Reports the pointer over <paramref name="display"/> now and whenever its shape or visibility
    /// changes, one call at a time, from any thread. Disposing the result stops it.
    /// </summary>
    IDisposable Watch(DisplayInfo display, Action<CursorState> onChange);
}

/// <summary>What the pointer looks like right now.</summary>
/// <param name="Shape">Its image when it changed; null when only the visibility changed.</param>
/// <param name="IsVisible">False while the system hides it (a game, typing in some apps, a touch-only session).</param>
/// <param name="X">Where it is, in points of the watched display.</param>
/// <param name="Y">Where it is, in points of the watched display.</param>
public sealed record CursorState(CursorShape? Shape, bool IsVisible, float X, float Y);
