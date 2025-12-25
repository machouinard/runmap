interface NavigationButtonsProps {
  isAdmin: boolean;
  onShowAdmin: () => void;
  onMobileClose?: () => void;
}

export function NavigationButtons({
  isAdmin,
  onShowAdmin,
  onMobileClose,
}: NavigationButtonsProps) {


  const handleShowAdmin = () => {
    onShowAdmin();
    onMobileClose?.();
  };

  return (
    <>


      {isAdmin && (
        <button
          onClick={handleShowAdmin}
          className="w-full px-4 py-2 bg-gray-800 hover:bg-gray-900 text-white rounded-md text-sm font-medium transition-colors"
        >
          Admin / Processing Queue
        </button>
      )}
    </>
  );
}
