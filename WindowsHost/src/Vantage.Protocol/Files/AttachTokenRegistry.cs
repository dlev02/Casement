using System.Net;
using System.Security.Cryptography;
using Vantage.Protocol.Net;

namespace Vantage.Protocol.Files;

/// <summary>
/// Tokens that let a second connection join an authenticated session as its file channel
/// (<c>Transfer/AttachTokenRegistry.swift</c>, spec §10.1): 32 random bytes, single use, bound to
/// the address (not port) of the connection they were issued on, valid 60 s, revoked with their
/// session. Thread-safe.
/// </summary>
public sealed class AttachTokenRegistry<TOwner> where TOwner : class
{
    /// <summary>Token size in bytes.</summary>
    public const int TokenLength = 32;

    private readonly TimeSpan _lifetime;
    private readonly TimeProvider _time;
    private readonly Lock _lock = new();
    private readonly List<Entry> _entries = [];

    public AttachTokenRegistry(TimeProvider? time = null, TimeSpan? lifetime = null)
    {
        _time = time ?? TimeProvider.System;
        _lifetime = lifetime ?? TimeSpan.FromSeconds(60);
    }

    /// <summary>Live tokens (for tests).</summary>
    public int Count
    {
        get { lock (_lock) return _entries.Count; }
    }

    /// <summary>A fresh token for <paramref name="owner"/>, usable once from <paramref name="peer"/>. Drops the owner's older tokens and expired ones.</summary>
    public byte[] Issue(TOwner owner, IPAddress peer)
    {
        var token = RandomNumberGenerator.GetBytes(TokenLength);
        var now = _time.GetUtcNow();
        lock (_lock)
        {
            _entries.RemoveAll(e => ReferenceEquals(e.Owner, owner) || e.Expires <= now);
            _entries.Add(new Entry(token, PeerPolicy.Normalize(peer), owner, now + _lifetime));
        }
        return token;
    }

    /// <summary>
    /// The owner <paramref name="token"/> was issued to, if it is live and <paramref name="peer"/>
    /// is where it was issued. Compares against every entry in constant time; a matching entry is
    /// removed whether or not the rest passes.
    /// </summary>
    public TOwner? Claim(ReadOnlySpan<byte> token, IPAddress peer)
    {
        var now = _time.GetUtcNow();
        peer = PeerPolicy.Normalize(peer);
        lock (_lock)
        {
            var match = -1;
            for (var index = 0; index < _entries.Count; index++)
            {
                if (CryptographicOperations.FixedTimeEquals(_entries[index].Token, token)) match = index;
            }
            Entry? entry = null;
            if (match >= 0)
            {
                entry = _entries[match];
                _entries.RemoveAt(match);
            }
            _entries.RemoveAll(e => e.Expires <= now);
            if (entry is null || !entry.Peer.Equals(peer) || entry.Expires <= now) return null;
            return entry.Owner;
        }
    }

    /// <summary>Drops the owner's token (its session ended).</summary>
    public void Revoke(TOwner owner)
    {
        lock (_lock) _entries.RemoveAll(e => ReferenceEquals(e.Owner, owner));
    }

    private sealed record Entry(byte[] Token, IPAddress Peer, TOwner Owner, DateTimeOffset Expires);
}
