import React from 'react';
import phone from '../../assets/call-calling.svg';
import mail from '../../assets/mail-01.svg';
import vector from '../../assets/Vector 7269.svg';

const Footer = () => {
  return (
    <footer className="bg-black text-white m-4 rounded-lg">
      <div className="max-w-7xl mx-auto flex justify-between items-center py-10 px-14 relative">
        <div className="w-1/3">
          <h3 className="font-bold text-lg">Contact Us</h3>
          <p className='text-green-600'>Have questions about how our AI works?</p>
          <div className="mt-2 flex items-center">
            <img src={phone} alt="phone" className="w-4 h-4" />
            <span className="ml-2">+91 99999 99999</span>
          </div>
          <div className="mt-2 flex items-center">
            <img src={mail} alt="mail" className="w-4 h-4" />
            <span className="ml-2">abc@gmail.com</span>
          </div>
        </div>
        <div className="absolute left-1/2 transform -translate-x-1/2">
          <img src={vector} alt="vector" className="w-auto h-32" />
        </div>
        <div className="w-1/3 text-left">
          <h3 className="font-bold text-lg">Privacy Note</h3>
          <p className="mt-2 text-semanticBlue">
            Your video will be securely processed, and its data will never be shared without your consent.
          </p>
        </div>
      </div>
    </footer>
  );
};

export default Footer;
