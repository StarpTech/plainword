import Backdrop from './components/Backdrop.jsx';
import Nav from './components/Nav.jsx';
import Hero from './components/Hero.jsx';
import Demo from './components/Demo.jsx';
import Features from './components/Features.jsx';
import VoiceSection from './components/VoiceSection.jsx';
import ContextSection from './components/ContextSection.jsx';
import Providers from './components/Providers.jsx';
import RecommendedModel from './components/RecommendedModel.jsx';
import DownloadCta from './components/DownloadCta.jsx';
import Footer from './components/Footer.jsx';

export default function App() {
  return (
    <div className="relative min-h-screen overflow-x-clip bg-canvas">
      <Backdrop />
      <Nav />
      <main className="relative">
        <Hero />
        <Demo />
        <Features />
        <VoiceSection />
        <ContextSection />
        <Providers />
        <RecommendedModel />
        <DownloadCta />
      </main>
      <Footer />
    </div>
  );
}
