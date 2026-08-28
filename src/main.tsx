import { createRoot } from 'react-dom/client';
import './index.css';

import VanityApp from './app/VanityApp.tsx';

const element = document.getElementById('root') as HTMLElement;
createRoot(element).render(<VanityApp />);
