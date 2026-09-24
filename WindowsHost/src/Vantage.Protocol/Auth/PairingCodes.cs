using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Vantage.Protocol.Auth;

/// <summary>What <see cref="PairingCodes.Consume"/> found.</summary>
public enum PairingCheck
{
    /// <summary>The code matched; it is now used up.</summary>
    Accepted,
    /// <summary>Wrong code. The fifth wrong guess burns the code.</summary>
    Incorrect,
    /// <summary>No code is showing, or it expired.</summary>
    Unavailable,
}

/// <summary>
/// The one-time pairing code shown on the host (<c>TrustStore</c> in the Mac host, spec §7.1):
/// six digits, created only when the user asks, one at a time, expiring after 10 minutes, burned
/// after 5 wrong guesses (counted per code, not per peer), compared in constant time. The 1 s
/// penalty per miss is the session's job. Thread-safe.
/// </summary>
public sealed class PairingCodes
{
    /// <summary>Wrong guesses before a code is burned.</summary>
    public const int MaxAttempts = 5;

    /// <summary>How long a shown code works.</summary>
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);

    private readonly Lock _lock = new();
    private readonly TimeProvider _time;
    private readonly string? _fixedCode;
    private string? _active;
    private DateTimeOffset _issuedAt;
    private int _misses;

    /// <param name="time">Clock for expiry.</param>
    /// <param name="fixedCode">DEBUG <c>--pairing-code</c>: always this code, and it never expires (it is still burned by 5 misses and used up by a success, then reissued by <see cref="NewCode"/>).</param>
    public PairingCodes(TimeProvider time, string? fixedCode = null)
    {
        _time = time;
        _fixedCode = fixedCode;
    }

    /// <summary>Raised (any thread) when the showing code stops working: used, expired, or burned. The UI hides it.</summary>
    public event Action? Cleared;

    /// <summary>The code showing now, or null.</summary>
    public string? Current
    {
        get { lock (_lock) return _active; }
    }

    /// <summary>
    /// When the showing code stops working (issued + 10 minutes), for a countdown; null when no code
    /// is showing or it is a fixed DEBUG code that never expires. A code can also end sooner (used
    /// or burned): watch <see cref="Cleared"/>.
    /// </summary>
    public DateTimeOffset? ExpiresAt
    {
        get
        {
            lock (_lock) return _active is null || _fixedCode is not null ? null : _issuedAt + Lifetime;
        }
    }

    /// <summary>
    /// Shows a new code (the user chose "Show Pairing Code"), replacing any old one and resetting
    /// the miss count. <c>%06d</c> of a uniform 0…999 999.
    /// </summary>
    public string NewCode()
    {
        lock (_lock)
        {
            _active = _fixedCode ?? RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6", CultureInfo.InvariantCulture);
            _issuedAt = _time.GetUtcNow();
            _misses = 0;
            return _active;
        }
    }

    /// <summary>Checks a code a client sent. Expiry is checked here.</summary>
    public PairingCheck Consume(string code)
    {
        bool cleared = false;
        PairingCheck result;
        lock (_lock)
        {
            if (_active is null)
            {
                result = PairingCheck.Unavailable;
            }
            else if (_fixedCode is null && _time.GetUtcNow() - _issuedAt > Lifetime)
            {
                ClearLocked();
                cleared = true;
                result = PairingCheck.Unavailable;
            }
            else if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(_active), Encoding.UTF8.GetBytes(code)))
            {
                _misses++;
                if (_misses >= MaxAttempts)
                {
                    ClearLocked();
                    cleared = true;
                }
                result = PairingCheck.Incorrect;
            }
            else
            {
                ClearLocked();
                cleared = true;
                result = PairingCheck.Accepted;
            }
        }
        if (cleared) Cleared?.Invoke();
        return result;
    }

    private void ClearLocked()
    {
        _active = null;
        _misses = 0;
    }
}
