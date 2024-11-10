// App.tsx (or App.js if not using TypeScript)
import Header from './Components/Header/Header';
import MainContent from './Components/MainContent/MainContent';
import Footer from './Components/Footer/Footer';

const App = () => {
  return (
    <div className="min-h-screen flex flex-col justify-between bg-gray-50">
    <Header />
    <MainContent />
    <Footer />
    
    </div>
  );
};

export default App;
