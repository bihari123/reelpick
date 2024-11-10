import React from 'react';

interface ButtonProps {
  children: React.ReactNode;
  className:string
  onClick?: () => void;
}

const Button: React.FC<ButtonProps> = ({ children,className, onClick }) => {
  return (
    <button
      onClick={onClick}
      className={className}
    >
      {children}
    </button>
  );
};

export default Button;
