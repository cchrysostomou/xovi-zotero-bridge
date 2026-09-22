// Command zotbridge-localgeta merges a reMarkable document's on-device
// .rm annotation strokes into its original PDF entirely locally, using
// rmapi's own annotation-compositing engine (github.com/juruen/rmapi's
// archive+annotations packages) without any cloud round-trip.
//
// It reads the document's files directly out of the xochitl data
// directory (<uuid>.content, <uuid>.pdf, <uuid>/<page>.rm) and writes
// the merged PDF to the given output path.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/juruen/rmapi/annotations"
	"github.com/juruen/rmapi/archive"
)

func main() {
	var (
		library         string
		docUUID         string
		output          string
		allPages        bool
		annotationsOnly bool
		pageNumbers     bool
	)

	flag.StringVar(&library, "library", "", "path to the xochitl data directory containing <uuid>.content etc. (required)")
	flag.StringVar(&docUUID, "uuid", "", "document uuid to export (required)")
	flag.StringVar(&output, "output", "", "output PDF path (required)")
	flag.BoolVar(&allPages, "a", false, "include all pages, not just annotated ones")
	flag.BoolVar(&annotationsOnly, "n", false, "export annotations only, without the PDF background")
	flag.BoolVar(&pageNumbers, "p", false, "add page numbers")
	flag.Parse()

	if library == "" || docUUID == "" || output == "" {
		fmt.Fprintln(os.Stderr, "usage: zotbridge-localgeta -library <xochitl-dir> -uuid <uuid> -output <file.pdf> [-a] [-n] [-p]")
		os.Exit(2)
	}

	z := archive.NewZip()
	if err := z.ReadFromDir(library, docUUID); err != nil {
		fmt.Fprintf(os.Stderr, "error: failed to read document %s from %s: %s\n", docUUID, library, err)
		os.Exit(1)
	}

	options := annotations.PdfGeneratorOptions{
		AddPageNumbers:  pageNumbers,
		AllPages:        allPages,
		AnnotationsOnly: annotationsOnly,
	}
	generator := annotations.CreatePdfGeneratorFromZip(z, output, options)
	if err := generator.Generate(); err != nil {
		fmt.Fprintf(os.Stderr, "error: failed to generate annotated pdf: %s\n", err)
		os.Exit(1)
	}

	fmt.Printf("Annotations generated in: %s\n", output)
}
