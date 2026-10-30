using System;
using System.Security.Cryptography;
using System.Text;

public static class CampusNetSrunCrypto
{
    public static string HmacMd5(string key, string message)
    {
        using (var hmac = new HMACMD5(Encoding.UTF8.GetBytes(key)))
        {
            var bytes = hmac.ComputeHash(Encoding.UTF8.GetBytes(message));
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }
    }

    public static string Sha1(string value)
    {
        using (var sha = SHA1.Create())
        {
            var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(value));
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }
    }

    private static uint[] ToWords(string value, bool includeLength)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var count = (bytes.Length + 3) / 4;
        var words = new uint[count + (includeLength ? 1 : 0)];
        for (var i = 0; i < bytes.Length; i++)
        {
            words[i >> 2] |= (uint)bytes[i] << ((i & 3) * 8);
        }
        if (includeLength)
        {
            words[count] = (uint)bytes.Length;
        }
        return words;
    }

    private static byte[] EncodeWords(uint[] words)
    {
        var bytes = new byte[words.Length * 4];
        for (var i = 0; i < words.Length; i++)
        {
            bytes[i * 4] = (byte)(words[i] & 0xff);
            bytes[i * 4 + 1] = (byte)((words[i] >> 8) & 0xff);
            bytes[i * 4 + 2] = (byte)((words[i] >> 16) & 0xff);
            bytes[i * 4 + 3] = (byte)((words[i] >> 24) & 0xff);
        }
        return bytes;
    }

    private static string CustomBase64(byte[] bytes)
    {
        const string standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const string custom = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA";
        var encoded = Convert.ToBase64String(bytes);
        var output = new StringBuilder(encoded.Length);
        foreach (var c in encoded)
        {
            var index = standard.IndexOf(c);
            output.Append(index >= 0 ? custom[index] : c);
        }
        return output.ToString();
    }

    public static string SrunInfo(string json, string token)
    {
        var v = ToWords(json, true);
        var k = ToWords(token, false);
        if (k.Length < 4)
        {
            Array.Resize(ref k, 4);
        }

        var n = v.Length - 1;
        var z = v[n];
        var y = v[0];
        const uint delta = 0x9E3779B9u;
        uint sum = 0;
        var rounds = 6 + 52 / (n + 1);

        unchecked
        {
            while (rounds-- > 0)
            {
                sum += delta;
                var e = (sum >> 2) & 3;
                for (var p = 0; p < n; p++)
                {
                    y = v[p + 1];
                    var m = ((z >> 5) ^ (y << 2));
                    m += ((y >> 3) ^ (z << 4)) ^ (sum ^ y);
                    m += k[(p & 3) ^ (int)e] ^ z;
                    z = v[p] += m;
                }

                y = v[0];
                var last = ((z >> 5) ^ (y << 2));
                last += ((y >> 3) ^ (z << 4)) ^ (sum ^ y);
                last += k[(n & 3) ^ (int)e] ^ z;
                z = v[n] += last;
            }
        }

        return "{SRBX1}" + CustomBase64(EncodeWords(v));
    }
}

