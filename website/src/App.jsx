import Backdrop from './components/Backdrop.jsx';
import Nav from './components/Nav.jsx';
import Hero from './components/Hero.jsx';
import Features from './components/Features.jsx';
import VoiceSection from './components/VoiceSection.jsx';
import Providers from './components/Providers.jsx';
import DownloadCta from './components/DownloadCta.jsx';
import Footer from './components/Footer.jsx';

export default function App() {
  return (
    <div className="relative min-h-screen overflow-hidden bg-canvas">
      <Backdrop />
      <div className="relative mx-auto max-w-[1040px] px-5 sm:px-8">
        <Nav />
        <Hero />
        <Features />
        <VoiceSection />
        <Providers />
        <DownloadCta />
        <Footer />
      </div>
    </div>
  );
}
