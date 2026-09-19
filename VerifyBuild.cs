// Post-build check that the resources LCPDFR reads at runtime are actually present and
// usable. Written after three separate failures that all compiled cleanly and only showed
// up in-game: no resources at all, then .dat file references silently dropped, then those
// files embedded with LF endings where the parser splits on CRLF.
using System;
using System.Collections;
using System.IO;
using System.Resources;
using dnlib.DotNet;

class VerifyBuild
{
    static int failures;

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) failures++;
    }

    static int Main(string[] args)
    {
        var mod = ModuleDefMD.Load(args[0]);
        var found = new Hashtable();

        foreach (var res in mod.Resources)
        {
            var er = res as EmbeddedResource;
            if (er == null) continue;
            byte[] data = er.GetResourceData();
            if (!res.Name.String.EndsWith(".resources")) { found[res.Name.String] = data.Length; continue; }
            try
            {
                using (var r = new ResourceReader(new MemoryStream(data)))
                    foreach (DictionaryEntry e in r)
                        found[res.Name.String + "|" + e.Key] = e.Value;
            }
            catch (Exception) { }
        }

        // The name list. Parsed with Regex(Environment.NewLine), so it must carry CRLF and
        // split into at least three sections: female names, male names, surnames.
        object names = found["LCPD_First_Response.Properties.Resources.resources|Names"];
        Check(names is string, "Names resource present");
        if (names is string n)
        {
            Check(n.Length > 1000, $"Names has content ({n.Length} chars)");
            Check(n.Contains("\r\n"), "Names uses CRLF, as FileParser expects");
            Check(n.Replace("\r\n", "\n").Split('\n').Length >= 3, "Names splits into 3+ sections");
        }

        foreach (string key in new[] { "Coordinates", "PoliceDepartments", "boatpos" })
        {
            object v = found["LCPD_First_Response.Properties.Resources.resources|" + key];
            Check(v is string s && s.Length > 100, key + " resource present with content");
        }

        // Translations, looked up by CultureHelper for every on-screen string.
        object accepted = found["LCPD_First_Response.Resources.Translations.en-US.resources|CALLOUT_ACCEPTED"];
        Check(accepted is string, "en-US translations present (CALLOUT_ACCEPTED)");

        Console.WriteLine(failures == 0 ? "  all resource checks passed" : $"  {failures} CHECK(S) FAILED");
        return failures == 0 ? 0 : 1;
    }
}
