using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vantage.Protocol.Messages;

/// <summary>String enum by raw value (<c>[JsonStringEnumMemberName]</c>); rejects numbers and unknown strings, as Swift does.</summary>
public sealed class StrictStringEnumConverter<TEnum>() : JsonStringEnumConverter<TEnum>(namingPolicy: null, allowIntegerValues: false)
    where TEnum : struct, Enum;

/// <summary>
/// UUIDs as uppercase strings, the way Swift's <c>UUID</c> encodes (<c>E621E1F8-C36C-…</c>).
/// Reading accepts either case.
/// </summary>
public sealed class UpperGuidJsonConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String) throw new JsonException("A UUID must be a string.");
        var text = reader.GetString();
        if (!Guid.TryParseExact(text, "D", out var value)) throw new JsonException($"Not a UUID: {text}");
        return value;
    }

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// <summary>
/// Swift's default <c>Date</c> coding (<c>deferredToDate</c>): a JSON number of seconds since
/// 2001-01-01T00:00:00Z, possibly fractional. Unix seconds − 978 307 200.
/// </summary>
public sealed class AppleReferenceDateJsonConverter : JsonConverter<DateTimeOffset>
{
    /// <summary>2001-01-01T00:00:00Z.</summary>
    public static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static double ToAppleSeconds(DateTimeOffset value) => (value - ReferenceDate).Ticks / (double)TimeSpan.TicksPerSecond;

    public static DateTimeOffset FromAppleSeconds(double seconds)
    {
        if (!double.IsFinite(seconds)) throw new JsonException("A date must be a finite number.");
        return ReferenceDate.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));
    }

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.Number) throw new JsonException("A date must be a number of seconds since 2001.");
        return FromAppleSeconds(reader.GetDouble());
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(ToAppleSeconds(value));
}

/// <summary><see cref="KeyModifiers"/> as its raw value, a plain JSON integer (Swift OptionSet coding).</summary>
public sealed class KeyModifiersJsonConverter : JsonConverter<KeyModifiers>
{
    public override KeyModifiers Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.Number || !reader.TryGetUInt32(out var raw))
            throw new JsonException("KeyModifiers must be an unsigned integer.");
        return (KeyModifiers)raw;
    }

    public override void Write(Utf8JsonWriter writer, KeyModifiers value, JsonSerializerOptions options) =>
        writer.WriteNumberValue((uint)value);
}

/// <summary>
/// Swift's synthesized Codable for an enum with associated values: a single-key object whose
/// payload is keyed <c>_0</c>. <c>{"display":{"_0":3}}</c>, <c>{"fitViewport":{"_0":{…viewport…}}}</c>.
/// </summary>
public sealed class DisplaySelectionJsonConverter : JsonConverter<DisplaySelection>
{
    public override DisplaySelection Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject) throw new JsonException("DisplaySelection must be an object.");
        reader.Read();
        if (reader.TokenType != JsonTokenType.PropertyName) throw new JsonException("DisplaySelection needs one case key.");
        var caseName = reader.GetString();
        reader.Read();
        if (reader.TokenType != JsonTokenType.StartObject) throw new JsonException("DisplaySelection case payload must be an object.");
        DisplaySelection? result = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var key = reader.GetString();
            reader.Read();
            if (key != "_0")
            {
                reader.Skip();
                continue;
            }
            result = caseName switch
            {
                "display" => new DisplaySelection.Display(ReadUInt32(ref reader)),
                "fitViewport" => new DisplaySelection.FitViewport(
                    JsonSerializer.Deserialize(ref reader, VantageJsonContext.Default.Viewport)
                    ?? throw new JsonException("fitViewport needs a viewport.")),
                _ => throw new JsonException($"Unknown DisplaySelection case '{caseName}'."),
            };
        }
        if (reader.TokenType != JsonTokenType.EndObject) throw new JsonException("Malformed DisplaySelection payload.");
        reader.Read(); // the outer object's end
        if (reader.TokenType != JsonTokenType.EndObject) throw new JsonException("DisplaySelection must have exactly one case key.");
        return result ?? throw new JsonException($"DisplaySelection case '{caseName}' is missing _0.");
    }

    private static uint ReadUInt32(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.Number || !reader.TryGetUInt32(out var value))
            throw new JsonException("A display id must be an unsigned 32-bit integer.");
        return value;
    }

    public override void Write(Utf8JsonWriter writer, DisplaySelection value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        switch (value)
        {
            case DisplaySelection.Display display:
                writer.WriteStartObject("display");
                writer.WriteNumber("_0", display.Id);
                writer.WriteEndObject();
                break;
            case DisplaySelection.FitViewport fit:
                writer.WriteStartObject("fitViewport");
                writer.WritePropertyName("_0");
                JsonSerializer.Serialize(writer, fit.Viewport, VantageJsonContext.Default.Viewport);
                writer.WriteEndObject();
                break;
            default:
                throw new JsonException($"Unknown DisplaySelection {value.GetType().Name}.");
        }
        writer.WriteEndObject();
    }
}
