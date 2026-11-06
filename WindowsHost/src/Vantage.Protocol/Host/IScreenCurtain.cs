using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// Blacks out the computer's own screen and ignores its own keyboard and mouse while the picture
/// stays the real desktop. One curtain per computer, up while any session wants it. Calls come from
/// any session's queue; implementations lock.
/// </summary>
public interface IScreenCurtain
{
    /// <summary>Raises or lowers it for <paramref name="owner"/>. Returns why it couldn't be raised, or null.</summary>
    /// <param name="wanted">Raise, or lower.</param>
    /// <param name="owner">The session asking.</param>
    /// <param name="notify">Told when the curtain comes down by itself (someone locked the computer).</param>
    string? Set(bool wanted, Guid owner, Action<CurtainStatus> notify);

    /// <summary>A session joins a curtain that's already up (left by one that ended). False if it isn't up.</summary>
    bool Adopt(Guid owner, Action<CurtainStatus> notify);

    /// <summary>The session ended. The curtain stays until a device lowers it or the computer locks.</summary>
    void SessionEnded(Guid owner);
}

/// <summary>A curtain with nothing behind it: synthetic hosts have no real screen to cover.</summary>
public sealed class PretendCurtain : IScreenCurtain
{
    /// <inheritdoc />
    public string? Set(bool wanted, Guid owner, Action<CurtainStatus> notify) => null;

    /// <inheritdoc />
    public bool Adopt(Guid owner, Action<CurtainStatus> notify) => false;

    /// <inheritdoc />
    public void SessionEnded(Guid owner)
    {
    }
}
