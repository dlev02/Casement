using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using Vantage.Protocol.Files;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;

namespace Vantage.Protocol.Tests;

internal static class Loopback
{
    /// <summary>Two started connections joined over 127.0.0.1.</summary>
    public static async Task<(FramedConnection Host, FramedConnection Client)> PairAsync(FramedConnectionOptions? options = null)
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var accept = listener.AcceptSocketAsync();
        var client = await FramedConnection.ConnectAsync("127.0.0.1", ((IPEndPoint)listener.LocalEndpoint).Port, options);
        var host = new FramedConnection(await accept, options);
        host.Start();
        return (host, client);
    }

    public static async Task<T> Next<T>(FramedConnection connection, TimeSpan? timeout = null) where T : class, IMessage
    {
        using var limit = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(10));
        while (await connection.ReceiveAsync(limit.Token) is { } message)
        {
            if (message is T wanted) return wanted;
        }
        throw new IOException($"closed before a {typeof(T).Name}");
    }
}

public sealed class FileEngineTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("vantage-engine-").FullName;

    public void Dispose() => Directory.Delete(_root, recursive: true);

    private string Folder(string name) => Directory.CreateDirectory(Path.Combine(_root, name)).FullName;

    private string MakeFile(string name, int size)
    {
        var path = Path.Combine(Folder("outbox"), name);
        File.WriteAllBytes(path, RandomNumberGenerator.GetBytes(size));
        return path;
    }

    private static FileTransferEngine Engine(FramedConnection connection, FileTransferRole role, string folder, TimeSpan? chunkDelay = null) =>
        new(connection, role, new FileTransferConfiguration { ReceiveDirectory = folder, ChunkDelay = chunkDelay ?? TimeSpan.Zero });

    [Fact]
    public async Task FilesCrossBothWaysAtOnce()
    {
        var (a, b) = await Loopback.PairAsync();
        var host = Engine(a, FileTransferRole.Host, Folder("host"));
        var client = Engine(b, FileTransferRole.Client, Folder("client"));
        _ = host.RunAsync();
        _ = client.RunAsync();
        var up = MakeFile("Up.bin", 3_000_000);
        // A Mac can name a file "Down <1>.bin"; Windows can't create one to send, so there the
        // renaming is left to FileNamesTests.
        var downName = OperatingSystem.IsWindows() ? "Down 1.bin" : "Down <1>.bin";
        var savedDown = OperatingSystem.IsWindows() ? "Down 1.bin" : "Down -1-.bin";
        var down = MakeFile(downName, 2_500_000);
        var results = await Task.WhenAll(client.SendAsync(up), host.SendAsync(down)).WaitAsync(TimeSpan.FromSeconds(30));
        Assert.Equal(new FileTransferOutcome.Sent("Up.bin"), results[0]);
        Assert.Equal(new FileTransferOutcome.Sent(savedDown), results[1]);
        Assert.Equal(File.ReadAllBytes(up), File.ReadAllBytes(Path.Combine(_root, "host", "Up.bin")));
        Assert.Equal(File.ReadAllBytes(down), File.ReadAllBytes(Path.Combine(_root, "client", savedDown)));

        // The same name again gets a Finder-style number, and empty files work.
        Assert.Equal(new FileTransferOutcome.Sent("Up 2.bin"), await client.SendAsync(up));
        Assert.Equal(new FileTransferOutcome.Sent("Empty.txt"), await client.SendAsync(MakeFile("Empty.txt", 0)));
        client.Close();
        host.Close();
    }

    [Fact]
    public async Task AnInterruptedFileResumesOnANewConnection()
    {
        var hostFolder = Folder("host");
        var source = MakeFile("Big.bin", 6_000_000);
        var id = Guid.NewGuid();

        var (a, b) = await Loopback.PairAsync();
        var host = Engine(a, FileTransferRole.Host, hostFolder);
        var client = Engine(b, FileTransferRole.Client, Folder("client"), TimeSpan.FromMilliseconds(15));
        _ = host.RunAsync();
        _ = client.RunAsync();
        var gotSome = new TaskCompletionSource();
        host.Events += e =>
        {
            if (e is FileTransferEvent.Progress { Bytes: > 1_500_000 }) gotSome.TrySetResult();
        };
        var first = client.SendAsync(source, id: id);
        await gotSome.Task.WaitAsync(TimeSpan.FromSeconds(20));
        a.Close(); // the connection drops mid-file
        Assert.IsType<FileTransferOutcome.Failed>(await first.WaitAsync(TimeSpan.FromSeconds(10)));
        await host.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        var partial = Path.Combine(hostFolder, FileTransferEngine.PartialName(id));
        var kept = new FileInfo(partial).Length;
        Assert.True(kept > 0, "the partial is kept for a resume");

        var (a2, b2) = await Loopback.PairAsync();
        var host2 = Engine(a2, FileTransferRole.Host, hostFolder);
        var client2 = Engine(b2, FileTransferRole.Client, Folder("client"));
        ulong? resumedAt = null;
        host2.Events += e =>
        {
            if (e is FileTransferEvent.Progress progress && resumedAt is null) resumedAt = progress.Bytes;
        };
        _ = host2.RunAsync();
        _ = client2.RunAsync();
        Assert.Equal(new FileTransferOutcome.Sent("Big.bin"), await client2.SendAsync(source, id: id).WaitAsync(TimeSpan.FromSeconds(30)));
        Assert.Equal((ulong)kept, resumedAt);
        Assert.Equal(File.ReadAllBytes(source), File.ReadAllBytes(Path.Combine(hostFolder, "Big.bin")));
        Assert.False(File.Exists(partial));
        client2.Close();
    }

    [Fact]
    public async Task DamageAndDuplicatesAreRefusedAndOtherKindsCloseTheChannel()
    {
        var hostFolder = Folder("host");
        var (a, b) = await Loopback.PairAsync();
        var host = Engine(a, FileTransferRole.Host, hostFolder);
        var run = host.RunAsync();
        var id = Guid.NewGuid();

        b.Post(new FileOffer { Id = id, Name = "x.bin", ByteCount = 10 });
        Assert.Equal(0ul, (await Loopback.Next<FileAccept>(b)).ResumeOffset);
        b.Post(new FileOffer { Id = id, Name = "x.bin", ByteCount = 10 });
        Assert.Equal("That file is already being transferred.", (await Loopback.Next<FileAccept>(b)).Rejected);
        b.Post(new FileChunk { ToHost = true, Id = id, Offset = 4, Data = new byte[4] });
        var damaged = await Loopback.Next<FileResult>(b);
        Assert.False(damaged.Ok);
        Assert.Equal("The file arrived damaged.", damaged.Error);
        Assert.False(File.Exists(Path.Combine(hostFolder, FileTransferEngine.PartialName(id))));

        var second = Guid.NewGuid();
        b.Post(new FileOffer { Id = second, Name = "y.bin", ByteCount = 4 });
        await Loopback.Next<FileAccept>(b);
        b.Post(new FileChunk { ToHost = true, Id = second, Offset = 0, Data = new byte[] { 1, 2, 3, 4 } });
        await b.SendAsync(new FileComplete { Id = second, Sha256 = new byte[32] });
        Assert.Equal("The file arrived damaged. Try sending it again.", (await Loopback.Next<FileResult>(b)).Error);

        b.Post(new FileOffer { Id = Guid.NewGuid(), Name = "z.bin", ByteCount = 100UL << 30 });
        Assert.StartsWith("The file is too large", (await Loopback.Next<FileAccept>(b)).Rejected);

        await b.SendAsync(new Ping { SentAtNanos = 1 });
        await run.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(host.HasClosed);
    }

    [Fact]
    public async Task CancellingMidFileDeletesThePartialOnTheOtherSide()
    {
        var hostFolder = Folder("host");
        var (a, b) = await Loopback.PairAsync();
        var host = Engine(a, FileTransferRole.Host, hostFolder);
        var client = Engine(b, FileTransferRole.Client, Folder("client"), TimeSpan.FromMilliseconds(20));
        _ = host.RunAsync();
        _ = client.RunAsync();
        var id = Guid.NewGuid();
        var hostOutcome = new TaskCompletionSource<FileTransferOutcome>();
        host.Events += e =>
        {
            if (e is FileTransferEvent.Finished finished) hostOutcome.TrySetResult(finished.Outcome);
            if (e is FileTransferEvent.Progress { Bytes: > 500_000 }) client.Cancel(id);
        };
        var outcome = await client.SendAsync(MakeFile("Cancel.bin", 4_000_000), id: id).WaitAsync(TimeSpan.FromSeconds(20));
        Assert.Equal(new FileTransferOutcome.Cancelled(false), outcome);
        Assert.Equal(new FileTransferOutcome.Cancelled(true), await hostOutcome.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.False(File.Exists(Path.Combine(hostFolder, FileTransferEngine.PartialName(id))));
        client.Close();
    }
}

public class FramedConnectionTests
{
    [Fact]
    public async Task PFramesAreRefusedWholeWhileTheVideoLaneIsFullAndDrainingIsAnnounced()
    {
        var (a, b) = await Loopback.PairAsync(new FramedConnectionOptions { MaxQueuedVideoFrames = 2 });
        var drained = new TaskCompletionSource();
        a.VideoDrained += () => drained.TrySetResult();
        // Nobody reads b, so the socket fills; big P-frames back the lane up.
        var big = new byte[4 << 20];
        var accepted = 0;
        var refused = 0;
        for (var i = 0; i < 40; i++)
        {
            var frame = new VideoFrame { Sequence = (ulong)i, CaptureNanos = 0, IsKeyframe = false, Width = 2, Height = 2, Data = big };
            if (a.PostVideo(frame, droppable: true)) accepted++; else refused++;
        }
        Assert.True(refused > 0, "some P-frames were dropped");
        Assert.True(a.PostVideo(new VideoFrame { Sequence = 99, CaptureNanos = 0, IsKeyframe = true, Width = 2, Height = 2, Data = big }, droppable: false),
                    "a keyframe is never dropped");
        a.Post(new Pong { EchoNanos = 7 });
        var received = 0;
        var sawPong = false;
        var sawKeyframe = false;
        while (!(sawPong && sawKeyframe) && await b.ReceiveAsync() is { } message)
        {
            if (message is Pong) sawPong = true;
            else if (message is VideoFrame { IsKeyframe: true }) sawKeyframe = true;
            else if (message is VideoFrame) received++;
        }
        Assert.Equal(accepted, received); // every accepted frame arrived whole, in order
        Assert.True(sawPong && sawKeyframe);
        await drained.Task.WaitAsync(TimeSpan.FromSeconds(5));
        a.Close();
        Assert.Null(await b.ReceiveAsync());
    }

    [Fact]
    public async Task UnknownKindsAreSkippedAndBadPayloadsReported()
    {
        var (a, b) = await Loopback.PairAsync();
        var raw = new byte[8 + 3];
        Wire.Frame.WriteHeader(raw, 99, 3);
        a.PostRaw(raw);
        a.PostRaw(Wire.Frame.Encode(MessageKind.Ping, "{}"u8));
        a.Post(new Ping { SentAtNanos = 5 });
        Assert.Equal(99, (await b.ReceiveAsync() as UnknownMessage)?.RawKind ?? 0);
        Assert.IsType<UndecodableMessage>(await b.ReceiveAsync());
        Assert.Equal(5ul, (await b.ReceiveAsync() as Ping)?.SentAtNanos);
        a.Close();
    }
}
