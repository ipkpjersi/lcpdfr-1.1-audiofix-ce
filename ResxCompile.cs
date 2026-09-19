// Compile a .resx to .resources, resolving external file references.
//
// mono's resgen silently ignores ResXFileRef entries, which point at .dat files holding
// the name lists, coordinates and police department data. A build missing those compiles
// and loads, then throws IndexOutOfRangeException the first time LCPDFR reads a name.
//
// ResXResourceReader with BasePath set resolves those references, which is what resgen
// should have done.
using System;
using System.Collections;
using System.IO;
using System.Resources;

class ResxCompile
{
    static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("usage: ResxCompile.exe <input.resx> <output.resources>");
            return 2;
        }

        try
        {
            using (var reader = new ResXResourceReader(args[0]))
            {
                // Relative file references are resolved against the resx's own directory.
                reader.BasePath = Path.GetDirectoryName(Path.GetFullPath(args[0]));
                using (var writer = new ResourceWriter(args[1]))
                {
                    int count = 0;
                    foreach (DictionaryEntry entry in reader)
                    {
                        object value = entry.Value;

                        // Normalise string resources to CRLF. LCPDFR's FileParser splits
                        // on Environment.NewLine, which is CRLF at runtime on Windows, so
                        // a resource carrying bare LF never splits and the first read of
                        // the name list throws IndexOutOfRangeException. The data files
                        // are stored with LF in git and only become CRLF on a Windows
                        // checkout, so a Linux build has to do this explicitly.
                        string text = value as string;
                        if (text != null)
                        {
                            value = text.Replace("\r\n", "\n").Replace("\n", "\r\n");
                        }

                        writer.AddResource((string)entry.Key, value);
                        count++;
                    }
                    writer.Generate();
                    Console.WriteLine(count);
                }
            }
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e.GetType().Name + ": " + e.Message);
            return 1;
        }
    }
}
