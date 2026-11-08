using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Transport;

/// <summary>
/// The video lane of a connection, as the session's video pipeline sees it: <c>videoConfig</c> and
/// <c>videoFrame</c> go here, and a droppable P-frame is refused while the lane is backed up.
/// <see cref="FramedConnection"/> is the real one; tests substitute a recorder.
/// </summary>
public interface IVideoLane
{
    /// <summary>The lane is at or over its limits: a droppable frame would be refused now.</summary>
    bool IsVideoBacklogged { get; }

    /// <summary>Queues a video-lane message; false when a <paramref name="droppable"/> one was refused (force an IDR once the lane drains).</summary>
    bool PostVideo(IMessage message, bool droppable);
}
