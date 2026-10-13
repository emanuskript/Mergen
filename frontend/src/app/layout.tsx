import type { Metadata } from "next";

import { Header } from "@/components/layout/Header";
import { TourProvider } from "@/components/tour/TourProvider";
import { JotaiProvider } from "@/lib/context/JotaiProvider";
import { ThemeProvider } from "@/lib/context/ThemeProvider";

import "./globals.css";

export const metadata: Metadata = {
  title: "Manuscript Layout Analysis",
  description: "Detect and annotate medieval manuscript layout elements using YOLO models",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="antialiased">
        <ThemeProvider>
          <JotaiProvider>
            <TourProvider>
              <Header />
              <main className="min-h-[calc(100vh-57px)]">{children}</main>
            </TourProvider>
          </JotaiProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
