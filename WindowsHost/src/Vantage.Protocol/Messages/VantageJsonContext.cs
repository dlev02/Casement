using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vantage.Protocol.Messages;

/// <summary>
/// Source-generated JSON metadata for every control message. Configured to match Swift's
/// <c>JSONEncoder</c>/<c>JSONDecoder</c> as the protocol uses them (spec §5): nulls omitted,
/// required keys enforced, nullable annotations respected (a null in a non-optional field throws),
/// strict integers, uppercase UUIDs.
/// </summary>
[JsonSourceGenerationOptions(
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    NumberHandling = JsonNumberHandling.Strict,
    RespectNullableAnnotations = true,
    RespectRequiredConstructorParameters = true,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    Converters = [typeof(UpperGuidJsonConverter)])]
[JsonSerializable(typeof(Hello))]
[JsonSerializable(typeof(Challenge))]
[JsonSerializable(typeof(Authenticate))]
[JsonSerializable(typeof(AuthResult))]
[JsonSerializable(typeof(DisplayList))]
[JsonSerializable(typeof(SelectDisplay))]
[JsonSerializable(typeof(StreamConfig))]
[JsonSerializable(typeof(ViewportChanged))]
[JsonSerializable(typeof(QualityFeedback))]
[JsonSerializable(typeof(StreamStats))]
[JsonSerializable(typeof(ClipboardPayload))]
[JsonSerializable(typeof(HostCommandMessage))]
[JsonSerializable(typeof(Ping))]
[JsonSerializable(typeof(Pong))]
[JsonSerializable(typeof(DisconnectMessage))]
[JsonSerializable(typeof(ProtocolErrorMessage))]
[JsonSerializable(typeof(AttachMedia))]
[JsonSerializable(typeof(TextInput))]
[JsonSerializable(typeof(ModifierState))]
[JsonSerializable(typeof(AudioRequest))]
[JsonSerializable(typeof(DictationControl))]
[JsonSerializable(typeof(CursorShape))]
[JsonSerializable(typeof(VideoConfig))]
[JsonSerializable(typeof(HostStatus))]
[JsonSerializable(typeof(AudioConfig))]
[JsonSerializable(typeof(DictationResult))]
[JsonSerializable(typeof(FileOffer))]
[JsonSerializable(typeof(FileAccept))]
[JsonSerializable(typeof(FileComplete))]
[JsonSerializable(typeof(FileResult))]
[JsonSerializable(typeof(FileCancel))]
[JsonSerializable(typeof(Viewport))]
[JsonSerializable(typeof(DisplayInfo))]
public sealed partial class VantageJsonContext : JsonSerializerContext
{
    /// <summary>
    /// The context used on the wire: the generated options plus relaxed escaping, so base64 '+'
    /// and non-ASCII names go out literally (Swift accepts either form; this is just smaller).
    /// </summary>
    public static VantageJsonContext Wire => s_wire ??= CreateWire();

    private static VantageJsonContext? s_wire;

    private static VantageJsonContext CreateWire()
    {
        JsonSerializerOptions generated = Default.Options;
        return new VantageJsonContext(new JsonSerializerOptions(generated)
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
    }
}
