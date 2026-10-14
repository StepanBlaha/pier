import AppSection from "@/components/AppSection";
import ClaudeSection from "@/components/ClaudeSection";
import CliSection from "@/components/CliSection";
import Features from "@/components/Features";
import Footer from "@/components/Footer";
import Header from "@/components/Header";
import Hero from "@/components/Hero";
import Install from "@/components/Install";
import JsonLd from "@/components/JsonLd";
import Why from "@/components/Why";

export default function Home() {
  return (
    <>
      <Header />
      <main id="main">
        <Hero />
        <Why />
        <Features />
        <AppSection />
        <CliSection />
        <ClaudeSection />
        <Install />
      </main>
      <Footer />
      <JsonLd />
    </>
  );
}
